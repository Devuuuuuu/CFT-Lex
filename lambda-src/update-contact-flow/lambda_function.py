import json
import boto3
from base64 import b64decode
import datetime
import os
from boto3.dynamodb.conditions import Key

# Config values now come from the Lambda's environment, set by
# 06-lambda-update-contact-flow.yaml, instead of being hardcoded here.
AUDIT_TABLE_NAME = os.environ['AUDIT_TABLE_NAME']
CODECOMMIT_REPO_NAME = os.environ.get('CODECOMMIT_REPO_NAME', 'Devops-Connect-SCM-BKP')
DATA_BKP_BUCKET_NAME = os.environ['DATA_BKP_BUCKET_NAME']

codecommit = boto3.client('codecommit')
ddb = boto3.resource("dynamodb")

# ---------------------------------------------------------------------------
# Cross-environment dependency mapping
# ---------------------------------------------------------------------------

class MissingDependencyError(Exception):
    pass


CONTACT_FLOW_TYPES = [
    'CONTACT_FLOW',
    'CUSTOMER_QUEUE',
    'CUSTOMER_HOLD',
    'CUSTOMER_WHISPER',
    'AGENT_HOLD',
    'AGENT_WHISPER',
    'OUTBOUND_WHISPER',
    'AGENT_TRANSFER',
    'QUEUE_TRANSFER',
    'CAMPAIGN',
]


def _paginate_connect(method, result_key, **kwargs):
    results = []
    response = method(**kwargs)
    results.extend(response.get(result_key, []))

    while response.get('NextToken'):
        kwargs['NextToken'] = response['NextToken']
        response = method(**kwargs)
        results.extend(response.get(result_key, []))

    return results


def _replace_values(value, replacements):
    if isinstance(value, str):
        return replacements.get(value, value)
    if isinstance(value, list):
        return [_replace_values(item, replacements) for item in value]
    if isinstance(value, dict):
        return {
            key: _replace_values(item, replacements)
            for key, item in value.items()
        }
    return value


def _get_environment_instance_ids(config):
    source_env = config.get('source')
    target_env = config.get('target')

    if not source_env or not target_env:
        raise Exception(
            "Migration config must contain both 'source' and 'target'."
        )

    table = ddb.Table('DevOps-Envt-Table')

    source_items = table.query(
        KeyConditionExpression=Key('Environment').eq(source_env)
    ).get('Items', [])

    target_items = table.query(
        KeyConditionExpression=Key('Environment').eq(target_env)
    ).get('Items', [])

    if not source_items:
        raise Exception(
            f"Source environment '{source_env}' was not found."
        )

    if not target_items:
        raise Exception(
            f"Target environment '{target_env}' was not found."
        )

    return source_items[0]['InstanceId'], target_items[0]['InstanceId']


def _map_queues(content, target_connect, target_instance_id):
    target_queues = _paginate_connect(
        target_connect.list_queues,
        'QueueSummaryList',
        InstanceId=target_instance_id,
        QueueTypes=['STANDARD'],
    )

    target_by_name = {
        item.get('Name'): item.get('Arn')
        for item in target_queues
        if item.get('Name') and item.get('Arn')
    }

    metadata = content.get('Metadata', {}).get('ActionMetadata', {})
    replacements = {}
    missing = []

    if not isinstance(metadata, dict):
        return content

    for meta in metadata.values():
        if not isinstance(meta, dict):
            continue

        queue_meta = meta.get('queue')
        if not isinstance(queue_meta, dict):
            continue

        queue_name = queue_meta.get('text')
        source_arn = queue_meta.get('id')

        if not queue_name or not source_arn:
            continue

        target_arn = target_by_name.get(queue_name)

        if target_arn:
            replacements[source_arn] = target_arn
            print(f"Queue mapped: {queue_name} -> {target_arn}")
        else:
            missing.append(f"Queue '{queue_name}'")

    if missing:
        raise MissingDependencyError(
            "Missing target dependencies: " + ", ".join(sorted(set(missing)))
        )

    return _replace_values(content, replacements)


def _map_operating_hours(content, target_connect, target_instance_id):
    target_hours = _paginate_connect(
        target_connect.list_hours_of_operations,
        'HoursOfOperationSummaryList',
        InstanceId=target_instance_id,
    )

    target_by_name = {
        item.get('Name'): item.get('Arn')
        for item in target_hours
        if item.get('Name') and item.get('Arn')
    }

    metadata = content.get('Metadata', {}).get('ActionMetadata', {})
    replacements = {}
    missing = []

    if not isinstance(metadata, dict):
        return content

    for meta in metadata.values():
        if not isinstance(meta, dict):
            continue

        hours_meta = meta.get('Hours')
        if not isinstance(hours_meta, dict):
            continue

        hours_name = hours_meta.get('text')
        source_arn = hours_meta.get('id')

        if not hours_name or not source_arn:
            continue

        target_arn = target_by_name.get(hours_name)

        if target_arn:
            replacements[source_arn] = target_arn
            print(f"Operating Hours mapped: {hours_name} -> {target_arn}")
        else:
            missing.append(f"Operating Hours '{hours_name}'")

    if missing:
        raise MissingDependencyError(
            "Missing target dependencies: " + ", ".join(sorted(set(missing)))
        )

    return _replace_values(content, replacements)


def _map_lambda_arns(content, target_lambda):
    replacements = {}
    missing = []

    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key == 'LambdaFunctionARN' and isinstance(item, str):
                    if item.startswith('arn:aws:lambda:'):
                        function_name = item.split(':function:', 1)[-1]

                        try:
                            target = target_lambda.get_function(
                                FunctionName=function_name
                            )
                            target_arn = target['Configuration']['FunctionArn']
                            replacements[item] = target_arn
                            print(
                                f"Lambda mapped: {function_name} -> {target_arn}"
                            )
                        except target_lambda.exceptions.ResourceNotFoundException:
                            missing.append(f"Lambda '{function_name}'")

                walk(item)

        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(content)

    if missing:
        raise MissingDependencyError(
            "Missing target dependencies: " + ", ".join(sorted(set(missing)))
        )

    return _replace_values(content, replacements)


def _map_contact_flow_arns(
    content,
    source_connect,
    target_connect,
    source_instance_id,
    target_instance_id,
):
    metadata = content.get('Metadata', {}).get('ActionMetadata', {})
    references = {}

    if not isinstance(metadata, dict):
        return content

    for meta in metadata.values():
        if not isinstance(meta, dict):
            continue

        flow_meta = meta.get('contactFlow')
        if not isinstance(flow_meta, dict):
            continue

        source_arn = flow_meta.get('id')
        flow_name = flow_meta.get('text')

        if source_arn and flow_name:
            references[source_arn] = flow_name

    if not references:
        return content

    target_flows = _paginate_connect(
        target_connect.list_contact_flows,
        'ContactFlowSummaryList',
        InstanceId=target_instance_id,
        ContactFlowTypes=CONTACT_FLOW_TYPES,
    )

    target_by_name_type = {
        (flow.get('Name'), flow.get('ContactFlowType')): flow.get('Arn')
        for flow in target_flows
        if flow.get('Name')
        and flow.get('ContactFlowType')
        and flow.get('Arn')
    }

    replacements = {}
    missing = []

    for source_arn, flow_name in references.items():
        source_flow_id = source_arn.rsplit('/', 1)[-1]

        source_flow = source_connect.describe_contact_flow(
            InstanceId=source_instance_id,
            ContactFlowId=source_flow_id,
        )['ContactFlow']

        source_type = source_flow.get('Type')
        target_arn = target_by_name_type.get((flow_name, source_type))

        if target_arn:
            replacements[source_arn] = target_arn
            print(
                f"Contact Flow mapped: {flow_name} "
                f"({source_type}) -> {target_arn}"
            )
        else:
            missing.append(
                f"Contact Flow '{flow_name}' (type '{source_type}')"
            )

    if missing:
        raise MissingDependencyError(
            "Missing target dependencies: " + ", ".join(sorted(set(missing)))
        )

    return _replace_values(content, replacements)


def prepare_migration_content(
    content,
    source_connect,
    target_connect,
    target_lambda,
    source_instance_id,
    target_instance_id,
):
    content = _map_queues(
        content, target_connect, target_instance_id
    )
    content = _map_operating_hours(
        content, target_connect, target_instance_id
    )
    content = _map_lambda_arns(
        content, target_lambda
    )
    content = _map_contact_flow_arns(
        content,
        source_connect,
        target_connect,
        source_instance_id,
        target_instance_id,
    )
    return content


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
            source_instance_id, target_instance_id = _get_environment_instance_ids(
                jsonObject
            )

            if target_instance_id != prodInstanceId:
                print(
                    f"Target instance in config ({prodInstanceId}) differs "
                    f"from environment table ({target_instance_id}); using "
                    f"the environment table target."
                )
                prodInstanceId = target_instance_id
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

            try:
                content = prepare_migration_content(
                    content=content,
                    source_connect=boto3.client('connect'),
                    target_connect=client,
                    target_lambda=boto3.client('lambda'),
                    source_instance_id=source_instance_id,
                    target_instance_id=prodInstanceId,
                )
            except MissingDependencyError as dependency_error:
                print("Dependency validation failed:", dependency_error)
                date = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                table = ddb.Table(AUDIT_TABLE_NAME)
                table.put_item(
                    Item={
                        'ProgressId': progressId,
                        'Username': user,
                        'Action': (
                            "Migration failed for " + cfname +
                            " contact flow due to missing dependency: " +
                            str(dependency_error)
                        ),
                        'Timestamp': date,
                        'Flowname': cfname
                    }
                )
                raise

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