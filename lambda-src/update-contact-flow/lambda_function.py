import json
import boto3
from base64 import b64decode
import datetime
import os

# Config values now come from the Lambda's environment, set by
# 06-lambda-update-contact-flow.yaml, instead of being hardcoded here.
AUDIT_TABLE_NAME = os.environ['AUDIT_TABLE_NAME']
CODECOMMIT_REPO_NAME = os.environ['CODECOMMIT_REPO_NAME']
DATA_BKP_BUCKET_NAME = os.environ['DATA_BKP_BUCKET_NAME']

codecommit = boto3.client('codecommit')
ddb = boto3.resource("dynamodb")


# lambda trigged from code pipeline
def lambda_handler(event, context):
    print('ev', event)
    # Every exit path from here MUST tell CodePipeline success or failure -
    # a bare exception with no PutJobFailureResult call leaves the pipeline
    # stage hanging instead of failing fast. job_id is grabbed up front so
    # the except block can always signal back even if something fails
    # before the job details are otherwise used.
    job_id = event['CodePipeline.job']['id']
    pipeline = boto3.client('codepipeline')

    try:
        response = codecommit.get_file(
            repositoryName=CODECOMMIT_REPO_NAME,
            filePath='config.json'
        )
        print(response)
        content = response['fileContent']
        # byte to json
        jsonObject = json.loads(content.decode())
        print(jsonObject)
        cfnames = jsonObject['prodContactFlowName']
        print(cfnames)
        progressId = jsonObject['ProgressId']
        print(progressId)
        user = jsonObject['user']
        print(user)
        content_type = jsonObject['type']
        print(content_type)
        for index, cfname in enumerate(cfnames):
            s3 = boto3.resource('s3')
            cfnamex = cfname + '.json'
            print(cfnamex)
            prodInstanceId = jsonObject['prodInstanceId']
            response = codecommit.get_file(
                repositoryName=CODECOMMIT_REPO_NAME,
                filePath=cfnamex
            )
            print(response)
            content = response['fileContent']
            # byte to json
            jsonObject2 = json.loads(content.decode())
            print(jsonObject2)
            content = json.loads(jsonObject2['Content'])
            print(content)
            print(type(content))
            print(prodInstanceId)

            client = boto3.client('connect')
            queue_summary_list = []
            q_response = client.list_queues(
                InstanceId=prodInstanceId,
                QueueTypes=['STANDARD']
            )
            queue_summary_list.extend(q_response.get('QueueSummaryList', []))
            while 'NextToken' in q_response and q_response['NextToken']:
                q_response = client.list_queues(
                    InstanceId=prodInstanceId,
                    QueueTypes=['STANDARD'],
                    NextToken=q_response['NextToken']
                )
                queue_summary_list.extend(q_response.get('QueueSummaryList', []))

            queue_details = {}
            action_metadata = content.get('Metadata', {}).get('ActionMetadata', {})
            if isinstance(action_metadata, dict):
                for key, values in action_metadata.items():
                    if isinstance(values, dict):
                        for key1, value1 in values.items():
                            if key1 == 'queue' and isinstance(value1, dict) and 'text' in value1:
                                queue_details.update({key: value1['text']})
            print("queue", queue_details)
            for key, values in queue_details.items():
                for i in queue_summary_list:
                    if i.get('Name') == values:
                        queue_details.update({key: i['Arn']})
            print(queue_details)
            if 'Actions' in content and isinstance(content['Actions'], list):
                for items in content['Actions']:
                    for key, value in queue_details.items():
                        if items.get('Type') == 'UpdateContactTargetQueue' and items.get('Identifier') == key:
                            items.setdefault('Parameters', {})['QueueId'] = value

            content = json.dumps(content)
            print('FInalCOntent', content)
            if content_type == "flow":
                # check whether the contact flow alreadys exists in prod envt or not
                try:
                    client = boto3.client('connect')
                    print('input', cfname)
                    print('content', content)
                    response = client.create_contact_flow(
                        InstanceId=prodInstanceId,
                        Name=cfname,
                        Type='CONTACT_FLOW',
                        Description='migrated flow from dev to prod',
                        Content=content
                    )
                    print("cf newly created")
                    print(response)
                    date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(date)
                    table = ddb.Table(AUDIT_TABLE_NAME)
                    table.put_item(
                        Item={
                            'ProgressId': progressId,
                            'Username': user,
                            'Action': "Migration started for " + cfname + " contact flow",
                            'Timestamp': date,
                            'Flowname': cfname
                        }
                    )
                    date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(date)
                    table.put_item(
                        Item={
                            'ProgressId': progressId,
                            'Username': user,
                            'Action': "Migration completed for " + cfname + " contact flow",
                            'Timestamp': date,
                            'Flowname': cfname
                        }
                    )
                except client.exceptions.InvalidContactFlowException as e:
                    print(e.response)
                    print(str(e.response))
                    date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(date)
                    table = ddb.Table(AUDIT_TABLE_NAME)
                    table.put_item(
                        Item={
                            'ProgressId': progressId,
                            'Username': user,
                            'Action': "Migration failed for " + cfname + " contact flow due to " + str(e.response),
                            'Timestamp': date,
                            'Flowname': cfname
                        }
                    )
                except client.exceptions.DuplicateResourceException as e:
                    print(e)
                    print('cf already exists.', prodInstanceId)
                    prodContactFlowId = ''
                    CFName = cfnamex.split('.')[0]
                    next_token = None
                    while True:
                        list_kwargs = {
                            'InstanceId': prodInstanceId,
                            'ContactFlowTypes': ['CONTACT_FLOW']
                        }
                        if next_token:
                            list_kwargs['NextToken'] = next_token
                        response = client.list_contact_flows(**list_kwargs)
                        for cf in response.get('ContactFlowSummaryList', []):
                            if cf.get('Name') == CFName:
                                prodContactFlowId = cf['Id']
                                break
                        if prodContactFlowId or 'NextToken' not in response or not response['NextToken']:
                            break
                        next_token = response['NextToken']

                    print('prodContactFlowId  ', prodContactFlowId)
                    print('flow_content', type(content))

                    flow_desc = client.describe_contact_flow(
                        InstanceId=prodInstanceId,
                        ContactFlowId=prodContactFlowId
                    )
                    cfinfo = flow_desc['ContactFlow']['Content']
                    print('cfinfo', cfinfo)
                    backup_content = {
                        "cfcontent": json.dumps(cfinfo),
                        "prodInstanceId": prodInstanceId,
                        "prodContactFlowId": prodContactFlowId,
                        "ProgressId": progressId,
                        "user": user
                    }
                    print(backup_content)

                    s3 = boto3.client('s3')
                    s3.put_object(
                        Body=json.dumps(backup_content),
                        Bucket=DATA_BKP_BUCKET_NAME,
                        Key=cfnamex
                    )
                    print("file sent to s3")
                    date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(date)
                    table = ddb.Table(AUDIT_TABLE_NAME)
                    table.put_item(
                        Item={
                            'ProgressId': progressId,
                            'Username': user,
                            'Action': "Migration started for " + cfname + " contact flow",
                            'Timestamp': date,
                            'Flowname': cfname
                        }
                    )

                    try:
                        print('flow_content2', content)
                        # updating the cf content in target env
                        response = client.update_contact_flow_content(
                            InstanceId=prodInstanceId,
                            ContactFlowId=prodContactFlowId,
                            Content=content
                        )
                        print(response)
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration completed for " + cfname + " contact flow",
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                    except client.exceptions.InvalidContactFlowException as e:
                        print(e.response)
                        print(str(e.response))
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration failed for " + cfname + " contact flow due to " + str(e.response),
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                except Exception as e:
                    print(e)
                    print(str(e))
                    date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(date)
                    table = ddb.Table(AUDIT_TABLE_NAME)
                    table.put_item(
                        Item={
                            'ProgressId': progressId,
                            'Username': user,
                            'Action': "Migration failed for " + cfname + " contact flow due to " + str(e),
                            'Timestamp': date,
                            'Flowname': cfname
                        }
                    )
            if content_type == "module":
                # check if prod Instance has the same flow
                client = boto3.client('connect')
                target_module_list = []
                exists = False
                moduleId = ""
                print("name ", cfname)
                response = client.list_contact_flow_modules(
                    InstanceId=prodInstanceId,
                    ContactFlowModuleState='ACTIVE'
                )
                print(response['ContactFlowModulesSummaryList'])
                for module in response['ContactFlowModulesSummaryList']:
                    target_module_list.append(module)
                while (response.get('NextToken') and response['NextToken'] != ''):
                    nextToken = response['NextToken']
                    response = client.list_contact_flow_modules(
                        InstanceId=prodInstanceId,
                        ContactFlowModuleState='ACTIVE',
                        NextToken=nextToken
                    )
                    print("inside while", len(response['ContactFlowModulesSummaryList']))
                    for module in response['ContactFlowModulesSummaryList']:
                        target_module_list.append(module)
                for module in target_module_list:
                    if module['Name'] == cfname:
                        print("module already exists")
                        print(module)
                        moduleId = module['Id']
                        exists = True
                response = {}
                if exists:
                    module_desc = client.describe_contact_flow_module(
                        InstanceId=prodInstanceId,
                        ContactFlowModuleId=moduleId
                    )
                    moduleInfo = module_desc['ContactFlowModule']['Content']
                    backup = {
                        "cfcontent": moduleInfo,
                        "prodInstanceId": prodInstanceId,
                        "prodContactFlowId": moduleId,
                        "ProgressId": progressId,
                        "user": user
                    }
                    try:
                        s3 = boto3.client('s3')
                        s3.put_object(
                            Body=json.dumps(backup),
                            Bucket=DATA_BKP_BUCKET_NAME,
                            Key=cfnamex
                        )
                        response = client.update_contact_flow_module_content(
                            InstanceId=prodInstanceId,
                            ContactFlowModuleId=moduleId,
                            Content=content
                        )
                        print(response)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration started for " + cfname + " contact flow module",
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration completed for " + cfname + " contact flow module",
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                    except client.exceptions.InvalidContactFlowException as e:
                        print(e.response)
                        print(str(e.response))
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration failed for " + cfname + " contact flow module due to " + str(e.response),
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                    except Exception as Error:
                        print(Error)
                        print(str(Error))
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration failed for " + cfname + " contact flow module due to " + str(Error),
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                else:
                    try:
                        response = client.create_contact_flow_module(
                            InstanceId=prodInstanceId,
                            Name=cfname,
                            Content=content,
                            Description="Module migrated from dev to prod"
                        )
                        print(response)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration started for " + cfname + " contact flow module",
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration completed for " + cfname + " contact flow module",
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                    except client.exceptions.InvalidContactFlowException as e:
                        print(e.response)
                        print(str(e.response))
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration failed for " + cfname + " contact flow module due to " + str(e.response),
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )
                    except Exception as Error:
                        print(Error)
                        print(str(Error))
                        date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                        print(date)
                        table = ddb.Table(AUDIT_TABLE_NAME)
                        table.put_item(
                            Item={
                                'ProgressId': progressId,
                                'Username': user,
                                'Action': "Migration failed for " + cfname + " contact flow module due to " + str(Error),
                                'Timestamp': date,
                                'Flowname': cfname
                            }
                        )

        # All flows/modules processed without an unhandled exception
        # bubbling out - tell CodePipeline this stage passed.
        response = pipeline.put_job_success_result(
            jobId=job_id
        )
        print(response)
        return response

    except Exception as e:
        print(e)
        print('Something failed.')
        # This is the actual fix: previously this just did `raise e`,
        # which does NOT reliably tell CodePipeline the job failed. A
        # Lambda-invoke pipeline action needs an explicit
        # PutJobFailureResult call, or the stage can sit waiting instead
        # of failing fast.
        try:
            pipeline.put_job_failure_result(
                jobId=job_id,
                failureDetails={
                    'type': 'JobFailed',
                    'message': str(e)[:5000]
                }
            )
        except Exception as signal_error:
            # If we can't even signal failure back to the pipeline,
            # log it clearly - this is the scenario that leaves a
            # stage hanging, so it needs to be loud in CloudWatch.
            print('Failed to report job failure to CodePipeline:', signal_error)
        raise e