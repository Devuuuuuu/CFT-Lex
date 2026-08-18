import json
import os
import time
import datetime
import boto3
import requests

# AWS clients
codecommit = boto3.client("codecommit")
codepipeline = boto3.client("codepipeline")
lexv2 = boto3.client("lexv2-models")
s3client = boto3.client("s3")
ddb = boto3.resource("dynamodb")


# Environment-specific configuration
CODECOMMIT_REPO_NAME = os.environ["CODECOMMIT_REPO_NAME"]
CODECOMMIT_BRANCH_NAME = os.environ.get(
    "CODECOMMIT_BRANCH_NAME",
    "master"
)

SOURCE_S3_BUCKET_NAME = os.environ["SOURCE_S3_BUCKET_NAME"]

LEX_AUDIT_TABLE_NAME = os.environ["LEX_AUDIT_TABLE_NAME"]


def wait_for_import(import_id):
    """
    Wait until the Lex import completes.
    """
    while True:

        response = lexv2.describe_import(
            importId=import_id
        )

        print(response)

        status = response["importStatus"]

        if status == "Completed":
            return response

        if status in [
            "Failed",
            "Deleting",
            "Deleted"
        ]:
            raise RuntimeError(
                f"Lex import failed. "
                f"ImportId={import_id}, "
                f"Status={status}"
            )

        time.sleep(3)


def wait_for_locale_build(
    bot_id,
    bot_version,
    locale_id
):
    """
    Wait until a Lex locale reaches Built state.
    """

    while True:

        response = lexv2.describe_bot_locale(
            botId=bot_id,
            botVersion=bot_version,
            localeId=locale_id
        )

        print(response)

        status = response["botLocaleStatus"]

        if status == "Built":
            return response

        if status in [
            "Failed",
            "Deleting",
            "Deleted"
        ]:
            raise RuntimeError(
                f"Lex locale build failed. "
                f"BotId={bot_id}, "
                f"LocaleId={locale_id}, "
                f"Status={status}"
            )

        time.sleep(3)


def upload_zip_to_lex(zip_key):
    """
    Upload a ZIP from S3 to the Lex create_upload_url endpoint.
    """

    upload_response = lexv2.create_upload_url()

    print(upload_response)

    upload_url = upload_response["uploadUrl"]
    import_id = upload_response["importId"]

    response = s3client.get_object(
        Bucket=SOURCE_S3_BUCKET_NAME,
        Key=zip_key
    )

    file_content = response["Body"].read()

    upload_result = requests.put(
        upload_url,
        data=file_content,
        headers={
            "Content-Type": "application/octet-stream"
        },
        timeout=120
    )

    upload_result.raise_for_status()

    print(
        f"Successfully uploaded {zip_key} "
        f"to Lex import URL"
    )

    return import_id


def publish_full_bot(json_object):
    """
    Handles the full bot import flow when config.json
    contains roleARN and prodBotName.
    """

    prod_bot_name = json_object["prodBotName"]
    role_arn = json_object["roleARN"]

    raw_zip = json_object["zipfile"]
    zip_name = raw_zip if isinstance(raw_zip, str) else raw_zip[0]
    zip_key = f"{zip_name}.zip" if not zip_name.endswith(".zip") else zip_name

    print("Production bot name:", prod_bot_name)
    print("Import role:", role_arn)
    print("ZIP:", zip_key)

    import_id = upload_zip_to_lex(zip_key)

    lexv2.start_import(
        importId=import_id,
        resourceSpecification={
            "botImportSpecification": {
                "botName": prod_bot_name,
                "roleArn": role_arn,
                "dataPrivacy": {
                    "childDirected": False
                },
                "idleSessionTTLInSeconds": 300
            }
        },
        mergeStrategy="Overwrite"
    )

    wait_for_import(import_id)

    print(
        f"Completed full Lex bot import: "
        f"{prod_bot_name}"
    )


def get_locale_id(bot_id, locale_name):
    """
    Find locale ID by locale name.
    """

    response = lexv2.list_bot_locales(
        botId=bot_id,
        botVersion="DRAFT"
    )

    print(response)

    for locale in response.get(
        "botLocaleSummaries",
        []
    ):

        if locale["localeName"] == locale_name:
            return locale["localeId"]

    raise RuntimeError(
        f"Locale '{locale_name}' not found "
        f"for bot '{bot_id}'"
    )


def publish_locales(json_object):
    """
    Handles locale-by-locale promotion.
    """

    zipfiles = json_object["zipfile"]
    locales = json_object["locales"]

    dev_bot_id = json_object["devBotID"]
    prod_bot_id = json_object["prodBotID"]

    migration_id = json_object["migrationid"]

    print("Dev Bot ID:", dev_bot_id)
    print("Prod Bot ID:", prod_bot_id)
    print("Locales:", locales)
    print("Migration ID:", migration_id)

    for index, locale in enumerate(locales):

        raw_zip = zipfiles[index]
        zip_key = f"{raw_zip}.zip" if not raw_zip.endswith(".zip") else raw_zip

        print(
            f"Processing locale: {locale}, "
            f"ZIP: {zip_key}"
        )

        import_id = upload_zip_to_lex(zip_key)

        locale_id = get_locale_id(
            prod_bot_id,
            locale
        )

        lexv2.start_import(
            importId=import_id,
            resourceSpecification={
                "botLocaleImportSpecification": {
                    "botId": prod_bot_id,
                    "botVersion": "DRAFT",
                    "localeId": locale_id
                }
            },
            mergeStrategy="Overwrite"
        )

        wait_for_import(import_id)

        lexv2.build_bot_locale(
            botId=prod_bot_id,
            botVersion="DRAFT",
            localeId=locale_id
        )

        wait_for_locale_build(
            bot_id=prod_bot_id,
            bot_version="DRAFT",
            locale_id=locale_id
        )

        timestamp = (
            datetime.datetime.now()
            .strftime("%Y-%m-%d %H:%M:%S")
        )

        table = ddb.Table(
            LEX_AUDIT_TABLE_NAME
        )

        table.put_item(
            Item={
                "ProgressId": migration_id,
                "Description": f"Built {locale} Locale",
                "Timestamp": timestamp
            }
        )

        print(
            f"Audit record created for {locale}"
        )

    # Create a new version from all current locales
    bot_version_locale_specification = {}

    response = lexv2.list_bot_locales(
        botId=prod_bot_id,
        botVersion="DRAFT"
    )

    for locale in response.get(
        "botLocaleSummaries",
        []
    ):

        locale_id = locale["localeId"]

        bot_version_locale_specification[
            locale_id
        ] = {
            "sourceBotVersion": "DRAFT"
        }

    print(
        "Bot version locale specification:",
        bot_version_locale_specification
    )

    version_response = lexv2.create_bot_version(
        botId=prod_bot_id,
        botVersionLocaleSpecification=
            bot_version_locale_specification
    )

    bot_version = version_response["botVersion"]

    print(
        "Created bot version:",
        bot_version
    )

    # Validate the created version
    lexv2.describe_bot_version(
        botId=prod_bot_id,
        botVersion=bot_version
    )

    # Find Prod alias
    aliases_response = lexv2.list_bot_aliases(
        botId=prod_bot_id
    )

    bot_alias_id = None

    for alias in aliases_response.get(
        "botAliasSummaries",
        []
    ):

        if alias["botAliasName"] == "Prod":
            bot_alias_id = alias["botAliasId"]
            break

    if not bot_alias_id:
        raise RuntimeError(
            "Prod alias was not found on the "
            f"target bot {prod_bot_id}"
        )

    lexv2.update_bot_alias(
        botAliasId=bot_alias_id,
        botAliasName="Prod",
        botVersion=bot_version,
        botId=prod_bot_id
    )

    print(
        f"Prod alias updated to version "
        f"{bot_version}"
    )


def lambda_handler(event, context):

    print("Received event:")
    print(event)

    try:

        response = codecommit.get_file(
            repositoryName=CODECOMMIT_REPO_NAME,
            filePath="config.json",
            commitSpecifier=CODECOMMIT_BRANCH_NAME
        )

        content = response["fileContent"]

        json_object = json.loads(
            content.decode("utf-8")
        )

        print("Migration configuration:")
        print(json_object)

        if "roleARN" in json_object:

            publish_full_bot(
                json_object
            )

        else:

            publish_locales(
                json_object
            )

        # Signal successful CodePipeline execution
        job_id = event[
            "CodePipeline.job"
        ]["id"]

        success_response = (
            codepipeline.put_job_success_result(
                jobId=job_id
            )
        )

        print(
            "CodePipeline success response:",
            success_response
        )

        return {
            "statusCode": 200,
            "body": json.dumps(
                "Lex promotion completed successfully"
            )
        }

    except Exception as exc:

        print(
            "Lex promotion failed:",
            str(exc)
        )

        # Explicitly notify CodePipeline
        # if a CodePipeline job ID is present.
        try:

            job_id = event[
                "CodePipeline.job"
            ]["id"]

            codepipeline.put_job_failure_result(
                jobId=job_id,
                failureDetails={
                    "type": "JobFailed",
                    "message": str(exc),
                    "externalExecutionId":
                        context.aws_request_id
                }
            )

        except Exception as pipeline_error:

            print(
                "Unable to report failure "
                f"to CodePipeline: {pipeline_error}"
            )

        raise