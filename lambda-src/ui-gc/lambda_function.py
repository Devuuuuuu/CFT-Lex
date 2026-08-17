import json
import boto3
from botocore.exceptions import ClientError
import os
import uuid
import datetime
from boto3.dynamodb.conditions import Key, Attr

# Config values now come from the Lambda's environment, set by
# 05-lambda-ui-gc.yaml, instead of being hardcoded here. This is what
# makes the stack portable across AWS accounts/environments without
# touching this file.
UI_GC_BUCKET_NAME = os.environ['UI_GC_BUCKET_NAME']
DATA_BKP_BUCKET_NAME = os.environ['DATA_BKP_BUCKET_NAME']
ENVT_TABLE_NAME = os.environ['ENVT_TABLE_NAME']
AUDIT_TABLE_NAME = os.environ['AUDIT_TABLE_NAME']
CODECOMMIT_REPO_NAME = os.environ['CODECOMMIT_REPO_NAME']
CODECOMMIT_BRANCH_NAME = os.environ['CODECOMMIT_BRANCH_NAME']


def lambda_handler(event, context):
    print("events->", event)

    # Detect API Gateway AWS_PROXY integration vs direct invocation
    is_api_gateway = False
    payload = event
    if isinstance(event, dict) and 'httpMethod' in event:
        is_api_gateway = True
        if event.get('httpMethod') == 'OPTIONS':
            return {
                "statusCode": 200,
                "headers": {
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token",
                    "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
                },
                "body": json.dumps({"message": "CORS preflight OK"})
            }
        if 'body' in event and event['body']:
            if isinstance(event['body'], str):
                try:
                    payload = json.loads(event['body'])
                except Exception:
                    payload = event['body']
            else:
                payload = event['body']

    def format_response(status_code, body_data):
        if is_api_gateway:
            return {
                "statusCode": status_code,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token",
                    "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
                },
                "body": json.dumps(body_data, default=str) if not isinstance(body_data, str) else body_data
            }
        return body_data

    s3 = boto3.client('s3')
    client = boto3.client('connect')
    codecommit = boto3.client('codecommit')
    ddb = boto3.resource('dynamodb')
    lamb = boto3.client('lambda')
    lex = boto3.client('lexv2-models')

    # Derived at runtime instead of hardcoded, so this works in whatever
    # account/region the stack is deployed to. AWS_REGION is a reserved
    # env var that Lambda sets automatically - you can read it but you
    # can't set it yourself in the CFN template.
    aws_region = os.environ.get('AWS_REGION', 'us-east-1')
    aws_account_id = context.invoked_function_arn.split(':')[4] if hasattr(context, 'invoked_function_arn') else '000000000000'

    req_type = payload.get('type') if isinstance(payload, dict) else None

    # generates config file
    if req_type == 'gc':
        uniqueid = uuid.uuid4()
        uniqueid = str(uniqueid)
        print(uniqueid)
        date = datetime.datetime.now()
        print(date, type(date))
        utc_offset = datetime.timedelta(hours=5, minutes=30)
        print(utc_offset, type(utc_offset))
        # Add the UTC offset to the local time
        date = date + utc_offset
        date = date.strftime("%Y-%m-%d %H:%M:%S")
        print('date modified= ', date)

        prodflowidlist = payload['prodflowidlist']
        flowlist = payload['flowlist']
        devflowidlist = payload['devflowidlist']
        src = payload["source"]
        tgt = payload["target"]
        table = ddb.Table(ENVT_TABLE_NAME)
        src_resp = table.query(
            KeyConditionExpression=Key('Environment').eq(src)
        )
        if not src_resp.get('Items'):
            return format_response(400, {"error": f"Source environment '{src}' not found in table"})
        src = src_resp['Items'][0]['InstanceId']
        print(src)

        tgt_resp = table.query(
            KeyConditionExpression=Key('Environment').eq(tgt)
        )
        if not tgt_resp.get('Items'):
            return format_response(400, {"error": f"Target environment '{tgt}' not found in table"})
        tgt = tgt_resp['Items'][0]['InstanceId']
        print(tgt)
        for index, flow in enumerate(flowlist):
            response = client.describe_contact_flow(
                InstanceId=src,
                ContactFlowId=devflowidlist[index]
            )
            print(response)
            cfinfo = response['ContactFlow']
            cfinfo = cfinfo['Content']
            filecontent = {
                "Content": cfinfo
            }
            filecontentstr = json.dumps(filecontent)
            print(filecontentstr)
            s3.put_object(
                Body=filecontentstr,
                Bucket=UI_GC_BUCKET_NAME,
                Key=flow + '.json'
            )
            print(str(index) + " flow file uploaded to s3")
        config = {
            "prodInstanceId": tgt,
            "prodContactFlowId": prodflowidlist,
            "prodContactFlowName": flowlist,
            "ProgressId": uniqueid,
            "user": payload["user"],
            "source": payload["source"],
            "target": payload["target"],
            "type": "flow"
        }
        s3.put_object(
            Body=json.dumps(config),
            Bucket=UI_GC_BUCKET_NAME,
            Key='config.json'
        )
        print("config file uploaded to s3")
        print("Success gc")
        return format_response(200, {
            "msg": "Success gc",
            "ProgressId": uniqueid
        })

    # Son uploads to s3 and commits
    if req_type == 'ju':
        print('ju ')
        bucket_name = UI_GC_BUCKET_NAME
        commitmsg = payload.get('commitmessage', "new changes to contact flows")
        # Get a list of the S3 objects in the specified bucket and prefix
        try:
            objects = s3.list_objects_v2(Bucket=bucket_name)['Contents']
        except KeyError:
            print('No objects found in the specified S3 bucket and prefix.')
            return format_response(400, 'No objects found in the specified S3 bucket and prefix.')

        # Define the CodeCommit repository and branch
        repo_name = CODECOMMIT_REPO_NAME
        branch_name = CODECOMMIT_BRANCH_NAME

        # Define an empty list to store the changes to commit
        changes = []

        # Loop through the S3 objects and add each one to the changes list
        for obj in objects:
            try:
                # Get the object content from S3
                response = s3.get_object(Bucket=bucket_name, Key=obj['Key'])
                file_content = response['Body'].read().decode('utf-8')

                # Create a file in CodeCommit with the same name as the S3 object, and add it to the changes list
                file_name = os.path.basename(obj['Key'])
                changes.append({
                    'filePath': file_name,
                    'fileMode': 'NORMAL',
                    'fileContent': file_content
                })
            except ClientError as e:
                print(f'Error adding file {file_name} to CodeCommit: {e}')

        # Commit the changes to CodeCommit
        try:
            print('jc codecommit')
            response = codecommit.get_branch(
                repositoryName=CODECOMMIT_REPO_NAME,
                branchName=CODECOMMIT_BRANCH_NAME
            )
            print(response)
            lastcommitId = response['branch']['commitId']
            print('lastcommitId', lastcommitId)
            response = codecommit.create_commit(
                repositoryName=repo_name,
                branchName=branch_name,
                putFiles=changes,
                commitMessage=commitmsg,
                parentCommitId=lastcommitId
            )
            print(response)
        except ClientError as e:
            print(f'Error creating commit in CodeCommit: {e}')
            return format_response(500, {
                "error": f"Failed to create CodeCommit commit: {str(e)}"
            })
        print("files uploaded from s3 to codecommit success")
        print("Success ju")
        return format_response(200, {
            "msg": "Success ju"
        })

    # reverts the flow changes to json files
    if req_type == 'revert':
        flowlist = payload['flowlist']
        print(flowlist, 'flowlist')
        username = payload.get('Username') or payload.get('user', 'system')
        for flow in flowlist:
            progressId = payload['progressId']
            bucket = DATA_BKP_BUCKET_NAME
            key = flow + '.json'
            response = s3.get_object(Bucket=bucket, Key=key)
            content = response['Body']
            jsonObject = json.loads(content.read())
            print(jsonObject)
            prodInstanceId = jsonObject['prodInstanceId']
            print(prodInstanceId)
            print(type(prodInstanceId))
            prodContactFlowId = jsonObject['prodContactFlowId']
            print(prodContactFlowId)
            print(type(prodContactFlowId))
            content = jsonObject['cfcontent']
            print(content)
            print(type(content))
            progressId = jsonObject['ProgressId']
            print(progressId)
            content_str = json.dumps(content) if isinstance(content, (dict, list)) else str(content)
            # update cf content
            client = boto3.client('connect')
            response = client.update_contact_flow_content(
                InstanceId=prodInstanceId,
                ContactFlowId=prodContactFlowId,
                Content=content_str
            )
            print(response)
            print("Reverted " + flow + " Flow")
            date = datetime.datetime.now()
            print(date, type(date))
            utc_offset = datetime.timedelta(hours=5, minutes=30)
            print(utc_offset, type(utc_offset))
            # Add the UTC offset to the local time
            date = date + utc_offset
            date = date.strftime("%Y-%m-%d %H:%M:%S")
            print('date modified= ', date)
            table = ddb.Table(AUDIT_TABLE_NAME)
            table.put_item(
                Item={
                    'Username': username,
                    'ProgressId': progressId,
                    'Action': "Reverted " + flow + " Flow",
                    'Timestamp': date,
                    'Flowname': flow
                }
            )
        print("Reverted Flow(s)")
        return format_response(200, {
            "msg": "Reverted Flow(s)"
        })

    # checks if production done by triggering the dynamo db for every 10 seconds
    if req_type == 'pd':
        flow = payload['flow']
        progressId = payload['progressId']
        description = 'Migration completed for ' + flow + ' contact flow'
        error = 'Migration failed for ' + flow + ' contact flow'
        table = ddb.Table(AUDIT_TABLE_NAME)
        response = table.scan(
            FilterExpression=Attr('ProgressId').eq(progressId)
        )
        items = response['Items']
        print(items)
        for item in items:
            desc = item['Action']
            ts = item['Timestamp']
            if description == desc:
                msg = description
                print(msg)
                return format_response(200, {
                    "msg": description,
                    "timestamp": ts
                })
            if error in desc:
                msg = desc
                print(msg)
                return format_response(200, {
                    "msg": msg,
                    "timestamp": ts
                })
        print("Migration not completed yet")
        return format_response(200, {
            "msg": "Migration not completed yet"
        })

    # lists contact flow of the src environment
    if req_type == 'getcontactflowslist':
        cflist = []
        src = payload["source"]
        response = client.list_contact_flows(
            InstanceId=src,
            ContactFlowTypes=[
                'CONTACT_FLOW',
            ],
        )
        print("list----", response)
        for cf in response['ContactFlowSummaryList']:
            cflist.append(cf)
        while 'NextToken' in response:
            nextToken = response['NextToken']
            response = client.list_contact_flows(
                InstanceId=src,
                ContactFlowTypes=[
                    'CONTACT_FLOW',
                ],
                NextToken=nextToken
            )
            print(response)
            for cf in response['ContactFlowSummaryList']:
                cflist.append(cf)

        print(cflist)
        return format_response(200, {
            "cflist": cflist
        })

    # checks the flow names in contact flow of src and tgt instances and returns them
    if req_type == 'getiddetails':
        flowname = payload['flowname']
        devFlowID = ""
        prodFlowID = ""
        src = payload["source"]
        tgt = payload["target"]
        table = ddb.Table(ENVT_TABLE_NAME)
        response1 = client.list_contact_flows(
            InstanceId=src,
            ContactFlowTypes=[
                'CONTACT_FLOW',
            ],
        )
        print(response1)
        contact_flows1 = response1['ContactFlowSummaryList']
        print(contact_flows1)
        for flow in contact_flows1:
            if flow['Name'] == flowname:
                devFlowID = flow['Id']
        while 'NextToken' in response1:
            nextToken = response1['NextToken']
            response1 = client.list_contact_flows(
                InstanceId=src,
                ContactFlowTypes=[
                    'CONTACT_FLOW',
                ],
                NextToken=nextToken
            )
            print(response1)
            contact_flows1 = response1['ContactFlowSummaryList']
            print(contact_flows1)
            for flow in contact_flows1:
                if flow['Name'] == flowname:
                    devFlowID = flow['Id']

        response2 = client.list_contact_flows(
            InstanceId=tgt,
            ContactFlowTypes=[
                'CONTACT_FLOW',
            ],
        )
        print(response2)
        contact_flows2 = response2['ContactFlowSummaryList']
        print(contact_flows2)
        for flow in contact_flows2:
            if flow['Name'] == flowname:
                prodFlowID = flow['Id']
        while 'NextToken' in response2:
            nextToken = response2['NextToken']
            response2 = client.list_contact_flows(
                InstanceId=tgt,
                ContactFlowTypes=[
                    'CONTACT_FLOW',
                ],
                NextToken=nextToken
            )
            print(response2)
            contact_flows2 = response2['ContactFlowSummaryList']
            print(contact_flows2)
            for flow in contact_flows2:
                if flow['Name'] == flowname:
                    prodFlowID = flow['Id']

        print(devFlowID + " " + prodFlowID)
        return format_response(200, {
            "devFlowID": devFlowID,
            "prodFlowID": prodFlowID
        })

    if req_type == 'jsoncf':
        cf = payload['cf']
        instanceId = payload['instanceId']
        flowId = None
        response1 = client.list_contact_flows(
            InstanceId=instanceId,
            ContactFlowTypes=[
                'CONTACT_FLOW',
            ],
        )
        print("list_contact_flows", response1)
        contact_flows1 = response1['ContactFlowSummaryList']
        print(contact_flows1)
        for flow in contact_flows1:
            if flow['Name'] == cf:
                flowId = flow['Id']
        while 'NextToken' in response1:
            nextToken = response1['NextToken']
            response1 = client.list_contact_flows(
                InstanceId=instanceId,
                ContactFlowTypes=[
                    'CONTACT_FLOW',
                ],
                NextToken=nextToken
            )
            print("inside loop print", response1)
            contact_flows1 = response1['ContactFlowSummaryList']
            print(contact_flows1)
            for flow in contact_flows1:
                if flow['Name'] == cf:
                    flowId = flow['Id']

        if not flowId:
            return format_response(404, {
                "error": f"Contact flow '{cf}' not found in instance '{instanceId}'"
            })

        response = client.describe_contact_flow(
            InstanceId=instanceId,
            ContactFlowId=flowId
        )
        cfinfo = response['ContactFlow']

        # Parse the Content field from JSON string to dictionary
        if 'Content' in cfinfo:
            try:
                cfinfo['Content'] = json.loads(cfinfo['Content'])
            except json.JSONDecodeError as e:
                return format_response(400, {
                    "error": f"Failed to decode Content field: {e}"
                })

        # Convert datetime object to string
        if 'LastModifiedTime' in cfinfo and isinstance(cfinfo['LastModifiedTime'], datetime.datetime):
            cfinfo['LastModifiedTime'] = cfinfo['LastModifiedTime'].isoformat()

        print("describe flow", cfinfo)
        return format_response(200, cfinfo['Content'])

    # gets the audit details to UI from Db
    if req_type == 'getaudit':
        table = ddb.Table(AUDIT_TABLE_NAME)
        response = table.scan()
        data = response['Items']
        print("All recorded user actions")
        print(data)
        return format_response(200, data)

    # console update for lex and lambda for the selected instance
    if req_type == 'consoleupdate':
        instanceId = payload['instanceId']
        lexBotIds = payload['botIds']
        lambdaNames = payload['lambdaNames']
        botAliasNames = payload['botAliasNames']
        lambdaArns = []
        for name in lambdaNames:
            resp2 = lamb.get_function(
                FunctionName=name
            )
            print('resp2', resp2)
            lambdaArns.append(resp2['Configuration']['FunctionArn'])

        for arnss in lambdaArns:
            resp1 = client.associate_lambda_function(
                InstanceId=instanceId,
                FunctionArn=arnss
            )
            print('resp1', resp1)

        lexAliases = []
        for index, ids in enumerate(lexBotIds):
            resp4 = lex.list_bot_aliases(botId=ids)
            print('resp4', resp4)
            for eachAlias in resp4['botAliasSummaries']:
                if botAliasNames[index] == eachAlias['botAliasName']:
                    aliasid = eachAlias['botAliasId']
                    aliasarn = f'arn:aws:lex:{aws_region}:{aws_account_id}:bot-alias/{ids}/{aliasid}'
                    lexAliases.append(aliasarn)

        print('LexAlias', lexAliases)

        for arnss in lexAliases:
            resp3 = client.associate_bot(
                InstanceId=instanceId,
                LexV2Bot={
                    'AliasArn': arnss
                }
            )
            print('resp3', resp3)

        return format_response(200, {
            "message": "console level updates for lex and lambda successful"
        })

    if req_type == 'getenvt':
        table = ddb.Table(ENVT_TABLE_NAME)
        response = table.scan()
        data = response['Items']
        data = [d['Environment'] for d in data]
        print("All Environments : ")
        print(data)
        return format_response(200, {
            "list": data
        })

    return format_response(400, {
        "error": f"Invalid or missing 'type' parameter in request: {req_type}"
    })