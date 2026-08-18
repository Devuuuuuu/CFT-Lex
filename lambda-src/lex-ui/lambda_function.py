import json
import boto3
import datetime
import requests
import os
import time
import uuid
from urllib.parse import urlparse

from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key


# AWS clients
codecommit = boto3.client("codecommit")
lexv2 = boto3.client("lexv2-models")
s3client = boto3.client("s3")
s3 = boto3.resource("s3")
ddb = boto3.resource("dynamodb")


# Environment-specific configuration
LEX_UI_BUCKET_NAME = os.environ["LEX_UI_BUCKET_NAME"]
CODECOMMIT_REPO_NAME = os.environ["CODECOMMIT_REPO_NAME"]
CODECOMMIT_BRANCH_NAME = os.environ.get("CODECOMMIT_BRANCH_NAME", "master")
LEX_AUDIT_TABLE_NAME = os.environ["LEX_AUDIT_TABLE_NAME"]


def lambda_handler(event, context):

    event_type = event.get("type")

    if event_type == "status":

        migrationid = event["migrationid"]
        locale = event["locale"]

        description = f"Built {locale} Locale"

        table = ddb.Table(LEX_AUDIT_TABLE_NAME)

        response = table.query(
            KeyConditionExpression=Key("ProgressId").eq(migrationid)
        )

        items = response.get("Items", [])

        print(items)

        for item in items:

            desc = item.get("Description")
            ts = item.get("Timestamp")

            if description == desc:
                return {
                    "msg": description,
                    "timestamp": ts
                }

        return {
            "msg": "Migration not completed yet"
        }

    elif event_type == "localelist":

        devBotID = event["devBotID"]
        prodBotID = event["prodBotID"]

        # prodBotID is retained because it is part of the
        # existing frontend request contract.
        print(f"Production Bot ID: {prodBotID}")

        response = lexv2.list_bot_locales(
            botId=devBotID,
            botVersion="DRAFT",
            sortBy={
                "attribute": "BotLocaleName",
                "order": "Ascending"
            },
            maxResults=123
        )

        print(response)

        locales = []

        botLocaleSummaries = response.get("botLocaleSummaries", [])

        for locale in botLocaleSummaries:

            localeName = locale["localeName"]
            locales.append(localeName)

        print(locales)

        return {
            "locales": locales
        }

    elif event_type == "startpromotion":

        devBotID = event["devBotID"]
        prodBotID = event["prodBotID"]

        print(f"Starting Lex migration: {devBotID} -> {prodBotID}")

        response = lexv2.list_bot_locales(
            botId=devBotID,
            botVersion="DRAFT",
            sortBy={
                "attribute": "BotLocaleName",
                "order": "Ascending"
            },
            maxResults=123
        )

        print(response)

        locales = []
        localeIds = []

        botLocaleSummaries = response.get("botLocaleSummaries", [])

        for locale in botLocaleSummaries:

            localeName = locale["localeName"]
            localeId = locale["localeId"]

            locales.append(localeName)
            localeIds.append(localeId)

        print("Locales:", locales)
        print("Locale IDs:", localeIds)

        zipfiles = []

        for localeId in localeIds:

            response = lexv2.create_export(
                resourceSpecification={
                    "botLocaleExportSpecification": {
                        "botId": devBotID,
                        "botVersion": "DRAFT",
                        "localeId": localeId
                    }
                },
                fileFormat="LexJson"
            )

            exportId = response["exportId"]

            print("Export ID:", exportId)

            downloadUrl = None

            while downloadUrl is None:

                response = lexv2.describe_export(
                    exportId=exportId
                )

                if response["exportStatus"] == "Completed":
                    downloadUrl = response["downloadUrl"]

                elif response["exportStatus"] in [
                    "Failed",
                    "Deleting",
                    "Deleted"
                ]:
                    raise RuntimeError(
                        f"Lex export failed. "
                        f"ExportId={exportId}, "
                        f"Status={response['exportStatus']}"
                    )

                else:
                    time.sleep(2)

            print("Download URL:", downloadUrl)

            # Download exported Lex package
            download_response = requests.get(
                downloadUrl,
                timeout=60
            )

            download_response.raise_for_status()

            # Extract filename robustly from the pre-signed URL
            path = urlparse(downloadUrl).path
            filename = path.split("/")[-1].rsplit(".", 1)[0]

            print("Export filename:", filename)

            zipfiles.append(filename)

            # Store export in temporary S3 bucket
            s3client.put_object(
                Bucket=LEX_UI_BUCKET_NAME,
                Key=f"{filename}.zip",
                Body=download_response.content
            )

            print(
                f"Uploaded to "
                f"s3://{LEX_UI_BUCKET_NAME}/{filename}.zip"
            )

        # Generate migration ID
        migrationid = str(uuid.uuid4())

        config = {
            "devBotID": devBotID,
            "prodBotID": prodBotID,
            "locales": locales,
            "zipfile": zipfiles,
            "migrationid": migrationid
        }

        print("Migration config:", config)

        # Store config.json in S3
        s3client.put_object(
            Body=json.dumps(config),
            Bucket=LEX_UI_BUCKET_NAME,
            Key="config.json"
        )

        print("config.json uploaded to S3")

        # Read all temporary files from S3
        try:

            response = s3client.list_objects_v2(
                Bucket=LEX_UI_BUCKET_NAME
            )

            objects = response.get("Contents", [])

        except ClientError as exc:

            print(f"Unable to list S3 objects: {exc}")
            raise

        if not objects:
            raise RuntimeError(
                f"No objects found in S3 bucket "
                f"{LEX_UI_BUCKET_NAME}"
            )

        changes = []

        # Convert S3 objects into CodeCommit files
        for obj in objects:

            key = obj["Key"]

            try:

                print("Processing:", key)

                response = s3client.get_object(
                    Bucket=LEX_UI_BUCKET_NAME,
                    Key=key
                )

                file_content = response["Body"].read()

                file_name = os.path.basename(key)

                changes.append(
                    {
                        "filePath": file_name,
                        "fileMode": "NORMAL",
                        "fileContent": file_content
                    }
                )

            except ClientError as exc:

                print(
                    f"Error reading "
                    f"{key} from S3: {exc}"
                )
                raise

        # Get latest CodeCommit commit
        branch_response = codecommit.get_branch(
            repositoryName=CODECOMMIT_REPO_NAME,
            branchName=CODECOMMIT_BRANCH_NAME
        )

        last_commit_id = (
            branch_response["branch"]["commitId"]
        )

        print(
            "Current CodeCommit commit:",
            last_commit_id
        )

        # Commit migration files
        commit_response = codecommit.create_commit(
            repositoryName=CODECOMMIT_REPO_NAME,
            branchName=CODECOMMIT_BRANCH_NAME,
            putFiles=changes,
            commitMessage="new changes to lex bot",
            parentCommitId=last_commit_id
        )

        print("CodeCommit response:", commit_response)

        # Clean temporary bucket after successful commit
        bucket = s3.Bucket(LEX_UI_BUCKET_NAME)
        bucket.objects.all().delete()

        print("Temporary S3 bucket contents cleaned")

        return {
            "migrationid": migrationid
        }

    else:

        raise ValueError(
            f"Unsupported event type: {event_type}"
        )