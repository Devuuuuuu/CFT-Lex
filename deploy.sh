#!/usr/bin/env bash

# ============================================================
# DevOps Connect - IVR + Lex Migration Safe Deployment Script
# ============================================================
# Rules:
#   1. First deployment: discover matching existing resources and reuse them.
#   2. Missing resources: let CloudFormation create them.
#   3. Existing root stack: never rediscover/reclassify resources.
#      CloudFormation remains the source of truth for that stack.
#   4. Persistent resources created by this project use Retain policies.
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deploy.config"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }
on_error() { local code=$?; error "Deployment failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"; exit "$code"; }
trap on_error ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || die "--config requires a file path"
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<USAGE
Usage:
  ./deploy.sh
  ./deploy.sh --config deploy.config

The script performs a preflight check, reuses matching resources on a
new deployment, and lets CloudFormation manage an existing stack on updates.
USAGE
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE"
log "Loading configuration: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

required_vars=(
    AWS_REGION PROJECT_NAME ENVIRONMENT STACK_NAME
    ROOT_TEMPLATE TEMPLATE_DIR TEMPLATE_S3_PREFIX DEPLOYMENT_BUCKET_PREFIX
    STORAGE_BUCKET_PREFIX UI_GC_SOURCE_DIR UI_GC_PACKAGE_NAME UI_GC_S3_KEY
    UPDATE_CONTACT_FLOW_SOURCE_DIR UPDATE_CONTACT_FLOW_PACKAGE_NAME UPDATE_CONTACT_FLOW_S3_KEY
    LEX_UI_SOURCE_DIR LEX_UI_PACKAGE_NAME LEX_UI_S3_KEY
    LEX_PUBLISH_SOURCE_DIR LEX_PUBLISH_PACKAGE_NAME LEX_PUBLISH_S3_KEY
    UI_GC_LAMBDA_MEMORY UI_GC_LAMBDA_TIMEOUT
    UPDATE_CONTACT_FLOW_LAMBDA_MEMORY UPDATE_CONTACT_FLOW_LAMBDA_TIMEOUT
    LEX_UI_LAMBDA_MEMORY LEX_UI_LAMBDA_TIMEOUT
    LEX_PUBLISH_LAMBDA_MEMORY LEX_PUBLISH_LAMBDA_TIMEOUT
    ENVIRONMENT_TABLE_NAME AUDIT_TRAIL_TABLE_NAME LEX_AUDIT_TABLE_NAME
    CODECOMMIT_REPOSITORY_NAME CODECOMMIT_BRANCH_NAME
    LEX_CODECOMMIT_REPOSITORY_NAME LEX_CODECOMMIT_BRANCH_NAME
    UI_LAMBDA_ROLE_NAME UPDATE_LAMBDA_ROLE_NAME PIPELINE_ROLE_NAME
    LEX_UI_LAMBDA_ROLE_NAME LEX_PUBLISH_LAMBDA_ROLE_NAME
    UI_GC_LAMBDA_NAME UPDATE_CONTACT_FLOW_LAMBDA_NAME
    LEX_UI_LAMBDA_NAME LEX_PUBLISH_LAMBDA_NAME
    API_NAME API_STAGE_NAME PIPELINE_NAME LEX_PIPELINE_NAME
    LEX_UI_BUCKET_NAME LEX_PUBLISH_BUCKET_NAME LOG_RETENTION_DAYS
)
for v in "${required_vars[@]}"; do
    [[ -n "${!v:-}" ]] || die "$v is required in deploy.config"
done

ROOT_TEMPLATE_PATH="$SCRIPT_DIR/$ROOT_TEMPLATE"
TEMPLATE_DIR_PATH="$SCRIPT_DIR/$TEMPLATE_DIR"
UI_GC_SOURCE_PATH="$SCRIPT_DIR/$UI_GC_SOURCE_DIR"
UPDATE_CONTACT_FLOW_SOURCE_PATH="$SCRIPT_DIR/$UPDATE_CONTACT_FLOW_SOURCE_DIR"
LEX_UI_SOURCE_PATH="$SCRIPT_DIR/$LEX_UI_SOURCE_DIR"
LEX_PUBLISH_SOURCE_PATH="$SCRIPT_DIR/$LEX_PUBLISH_SOURCE_DIR"
BUILD_DIR="$SCRIPT_DIR/.deploy"
PACKAGE_DIR="$BUILD_DIR/packages"
mkdir -p "$PACKAGE_DIR"

aws_cmd() {
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
    else
        aws --region "$AWS_REGION" "$@"
    fi
}

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_command aws
require_command zip
[[ -f "$ROOT_TEMPLATE_PATH" ]] || die "Root template not found: $ROOT_TEMPLATE_PATH"
[[ -d "$TEMPLATE_DIR_PATH" ]] || die "Template directory not found: $TEMPLATE_DIR_PATH"
[[ -d "$UI_GC_SOURCE_PATH" ]] || die "UI-GC Lambda source not found: $UI_GC_SOURCE_PATH"
[[ -d "$UPDATE_CONTACT_FLOW_SOURCE_PATH" ]] || die "Update Contact Flow Lambda source not found: $UPDATE_CONTACT_FLOW_SOURCE_PATH"
[[ -d "$LEX_UI_SOURCE_PATH" ]] || die "Lex UI Lambda source not found: $LEX_UI_SOURCE_PATH"
[[ -d "$LEX_PUBLISH_SOURCE_PATH" ]] || die "Lex Publish Lambda source not found: $LEX_PUBLISH_SOURCE_PATH"

log "Validating AWS credentials..."
CALLER_IDENTITY="$(aws_cmd sts get-caller-identity --output json)"
AWS_ACCOUNT_ID="$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)"
CALLER_ARN="$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)"
success "Authenticated as $CALLER_ARN (Account: $AWS_ACCOUNT_ID, Region: $AWS_REGION)"

# ------------------------------------------------------------
# Deployment bucket.
# ------------------------------------------------------------
bucket_exists() {
    local b="$1"
    aws_cmd s3api head-bucket --bucket "$b" >/dev/null 2>&1
}

if [[ -z "${DEPLOYMENT_BUCKET:-}" ]]; then
    DEPLOYMENT_BUCKET="${DEPLOYMENT_BUCKET_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    log "No deployment bucket specified. Using convention: $DEPLOYMENT_BUCKET"
fi

if bucket_exists "$DEPLOYMENT_BUCKET"; then
    log "Deployment bucket exists: $DEPLOYMENT_BUCKET"
else
    log "Creating deployment bucket: $DEPLOYMENT_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws_cmd s3api create-bucket --bucket "$DEPLOYMENT_BUCKET"
    else
        aws_cmd s3api create-bucket --bucket "$DEPLOYMENT_BUCKET" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    aws_cmd s3api put-bucket-versioning --bucket "$DEPLOYMENT_BUCKET" \
        --versioning-configuration Status=Enabled
    aws_cmd s3api put-public-access-block --bucket "$DEPLOYMENT_BUCKET" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    success "Deployment bucket created: $DEPLOYMENT_BUCKET"
fi

# ------------------------------------------------------------
# Existing root stack state.
# ------------------------------------------------------------
ROOT_STACK_EXISTS="false"
if aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    ROOT_STACK_EXISTS="true"
    log "Existing root stack detected: $STACK_NAME"
fi

get_stack_parameter() {
    local param_name="$1"
    aws_cmd cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Parameters[?ParameterKey=='$param_name'].ParameterValue | [0]" \
        --output text 2>/dev/null || true
}

if [[ "$ROOT_STACK_EXISTS" == "true" ]]; then
    log "Re-populating existing-resource overrides from stack parameters..."
    # IVR
    value="$(get_stack_parameter ExistingMigrationBucketName)"; [[ "$value" != "None" ]] && EXISTING_MIGRATION_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingBackupBucketName)"; [[ "$value" != "None" ]] && EXISTING_BACKUP_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingArtifactBucketName)"; [[ "$value" != "None" ]] && EXISTING_ARTIFACT_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingEnvironmentTableName)"; [[ "$value" != "None" ]] && EXISTING_ENVIRONMENT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingAuditTableName)"; [[ "$value" != "None" ]] && EXISTING_AUDIT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingRepositoryName)"; [[ "$value" != "None" ]] && EXISTING_REPOSITORY_NAME="$value"
    value="$(get_stack_parameter ExistingUILambdaRoleArn)"; [[ "$value" != "None" ]] && EXISTING_UI_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingUpdateLambdaRoleArn)"; [[ "$value" != "None" ]] && EXISTING_UPDATE_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingPipelineRoleArn)"; [[ "$value" != "None" ]] && EXISTING_PIPELINE_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingUiGcLambdaArn)"; [[ "$value" != "None" ]] && EXISTING_UI_GC_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingUpdateContactFlowLambdaArn)"; [[ "$value" != "None" ]] && EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingApiId)"; [[ "$value" != "None" ]] && EXISTING_API_ID="$value"
    value="$(get_stack_parameter ExistingApiRootResourceId)"; [[ "$value" != "None" ]] && EXISTING_API_ROOT_RESOURCE_ID="$value"
    value="$(get_stack_parameter ExistingLexResourceId)"; [[ "$value" != "None" ]] && EXISTING_LEX_RESOURCE_ID="$value"
    value="$(get_stack_parameter ExistingPipelineName)"; [[ "$value" != "None" ]] && EXISTING_PIPELINE_NAME="$value"
    value="$(get_stack_parameter ExistingUIGCLogGroupName)"; [[ "$value" != "None" ]] && EXISTING_UI_GC_LOG_GROUP_NAME="$value"
    value="$(get_stack_parameter ExistingUpdateFlowLogGroupName)"; [[ "$value" != "None" ]] && EXISTING_UPDATE_FLOW_LOG_GROUP_NAME="$value"
    # Lex
    value="$(get_stack_parameter ExistingLexUiBucketName)"; [[ "$value" != "None" ]] && EXISTING_LEX_UI_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingLexPublishBucketName)"; [[ "$value" != "None" ]] && EXISTING_LEX_PUBLISH_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingLexAuditTableName)"; [[ "$value" != "None" ]] && EXISTING_LEX_AUDIT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingLexRepositoryName)"; [[ "$value" != "None" ]] && EXISTING_LEX_REPOSITORY_NAME="$value"
    value="$(get_stack_parameter ExistingLexUILambdaRoleArn)"; [[ "$value" != "None" ]] && EXISTING_LEX_UI_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingLexPublishLambdaRoleArn)"; [[ "$value" != "None" ]] && EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingLexUILambdaArn)"; [[ "$value" != "None" ]] && EXISTING_LEX_UI_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingLexPublishLambdaArn)"; [[ "$value" != "None" ]] && EXISTING_LEX_PUBLISH_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingLexPipelineName)"; [[ "$value" != "None" ]] && EXISTING_LEX_PIPELINE_NAME="$value"
    value="$(get_stack_parameter ExistingLexUILogGroupName)"; [[ "$value" != "None" ]] && EXISTING_LEX_UI_LOG_GROUP_NAME="$value"
    value="$(get_stack_parameter ExistingLexPublishLogGroupName)"; [[ "$value" != "None" ]] && EXISTING_LEX_PUBLISH_LOG_GROUP_NAME="$value"
    # Frontend
    value="$(get_stack_parameter ExistingFrontendBucketName)"; [[ "$value" != "None" ]] && EXISTING_FRONTEND_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingCloudFrontDistributionId)"; [[ "$value" != "None" ]] && EXISTING_CLOUDFRONT_DISTRIBUTION_ID="$value"
    value="$(get_stack_parameter ExistingCloudFrontDomainName)"; [[ "$value" != "None" ]] && EXISTING_CLOUDFRONT_DOMAIN_NAME="$value"
fi

if [[ "$ROOT_STACK_EXISTS" == "false" && "${AUTO_REUSE_EXISTING:-true}" == "true" ]]; then
    log "No existing root stack found. Running existing-resource discovery..."

    STORAGE_MIGRATION_EXPECTED="${STORAGE_BUCKET_PREFIX}-ui-gc-${AWS_ACCOUNT_ID}"
    STORAGE_BACKUP_EXPECTED="${STORAGE_BUCKET_PREFIX}-backup-${AWS_ACCOUNT_ID}"
    STORAGE_ARTIFACT_EXPECTED="${STORAGE_BUCKET_PREFIX}-artifacts-${AWS_ACCOUNT_ID}"

    if [[ -z "${EXISTING_MIGRATION_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_MIGRATION_EXPECTED"; then EXISTING_MIGRATION_BUCKET_NAME="$STORAGE_MIGRATION_EXPECTED"; fi
    if [[ -z "${EXISTING_BACKUP_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_BACKUP_EXPECTED"; then EXISTING_BACKUP_BUCKET_NAME="$STORAGE_BACKUP_EXPECTED"; fi
    if [[ -z "${EXISTING_ARTIFACT_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_ARTIFACT_EXPECTED"; then EXISTING_ARTIFACT_BUCKET_NAME="$STORAGE_ARTIFACT_EXPECTED"; fi
    if [[ -z "${EXISTING_LEX_UI_BUCKET_NAME:-}" ]] && bucket_exists "$LEX_UI_BUCKET_NAME"; then EXISTING_LEX_UI_BUCKET_NAME="$LEX_UI_BUCKET_NAME"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_BUCKET_NAME:-}" ]] && bucket_exists "$LEX_PUBLISH_BUCKET_NAME"; then EXISTING_LEX_PUBLISH_BUCKET_NAME="$LEX_PUBLISH_BUCKET_NAME"; fi

    if [[ -z "${EXISTING_ENVIRONMENT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "$ENVIRONMENT_TABLE_NAME" >/dev/null 2>&1; then EXISTING_ENVIRONMENT_TABLE_NAME="$ENVIRONMENT_TABLE_NAME"; fi
    if [[ -z "${EXISTING_AUDIT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "$AUDIT_TRAIL_TABLE_NAME" >/dev/null 2>&1; then EXISTING_AUDIT_TABLE_NAME="$AUDIT_TRAIL_TABLE_NAME"; fi
    if [[ -z "${EXISTING_LEX_AUDIT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "$LEX_AUDIT_TABLE_NAME" >/dev/null 2>&1; then EXISTING_LEX_AUDIT_TABLE_NAME="$LEX_AUDIT_TABLE_NAME"; fi

    if [[ -z "${EXISTING_REPOSITORY_NAME:-}" ]] && aws_cmd codecommit get-repository --repository-name "$CODECOMMIT_REPOSITORY_NAME" >/dev/null 2>&1; then EXISTING_REPOSITORY_NAME="$CODECOMMIT_REPOSITORY_NAME"; fi
    if [[ -z "${EXISTING_LEX_REPOSITORY_NAME:-}" ]] && aws_cmd codecommit get-repository --repository-name "$LEX_CODECOMMIT_REPOSITORY_NAME" >/dev/null 2>&1; then EXISTING_LEX_REPOSITORY_NAME="$LEX_CODECOMMIT_REPOSITORY_NAME"; fi

    if [[ -z "${EXISTING_UI_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$UI_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_UI_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$UI_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_UPDATE_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$UPDATE_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_UPDATE_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$UPDATE_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_PIPELINE_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$PIPELINE_ROLE_NAME" >/dev/null 2>&1; then EXISTING_PIPELINE_ROLE_ARN="$(aws_cmd iam get-role --role-name "$PIPELINE_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_UI_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$LEX_UI_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_LEX_UI_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$LEX_UI_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$LEX_PUBLISH_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$LEX_PUBLISH_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi

    if [[ -z "${EXISTING_UI_GC_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$UI_GC_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_UI_GC_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$UI_GC_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$UPDATE_CONTACT_FLOW_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$UPDATE_CONTACT_FLOW_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_UI_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$LEX_UI_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_LEX_UI_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$LEX_UI_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$LEX_PUBLISH_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_LEX_PUBLISH_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$LEX_PUBLISH_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi

    if [[ -z "${EXISTING_API_ID:-}" ]]; then
        EXISTING_API_ID="$(aws_cmd apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id | [0]" --output text 2>/dev/null || true)"
        [[ "$EXISTING_API_ID" == "None" ]] && EXISTING_API_ID=""
    fi

    if [[ -z "${EXISTING_PIPELINE_NAME:-}" ]] && aws_cmd codepipeline get-pipeline --name "$PIPELINE_NAME" >/dev/null 2>&1; then EXISTING_PIPELINE_NAME="$PIPELINE_NAME"; fi
    if [[ -z "${EXISTING_LEX_PIPELINE_NAME:-}" ]] && aws_cmd codepipeline get-pipeline --name "$LEX_PIPELINE_NAME" >/dev/null 2>&1; then EXISTING_LEX_PIPELINE_NAME="$LEX_PIPELINE_NAME"; fi

    UI_LOG_GROUP="/aws/lambda/$UI_GC_LAMBDA_NAME"
    UPDATE_LOG_GROUP="/aws/lambda/$UPDATE_CONTACT_FLOW_LAMBDA_NAME"
    LEX_UI_LOG_GROUP="/aws/lambda/$LEX_UI_LAMBDA_NAME"
    LEX_PUBLISH_LOG_GROUP="/aws/lambda/$LEX_PUBLISH_LAMBDA_NAME"
    if [[ -z "${EXISTING_UI_GC_LOG_GROUP_NAME:-}" ]] && aws_cmd logs describe-log-groups --log-group-name-prefix "$UI_LOG_GROUP" --query "logGroups[?logGroupName=='${UI_LOG_GROUP}'].logGroupName | [0]" --output text | grep -qv '^None$'; then EXISTING_UI_GC_LOG_GROUP_NAME="$UI_LOG_GROUP"; fi
    if [[ -z "${EXISTING_UPDATE_FLOW_LOG_GROUP_NAME:-}" ]] && aws_cmd logs describe-log-groups --log-group-name-prefix "$UPDATE_LOG_GROUP" --query "logGroups[?logGroupName=='${UPDATE_LOG_GROUP}'].logGroupName | [0]" --output text | grep -qv '^None$'; then EXISTING_UPDATE_FLOW_LOG_GROUP_NAME="$UPDATE_LOG_GROUP"; fi
    if [[ -z "${EXISTING_LEX_UI_LOG_GROUP_NAME:-}" ]] && aws_cmd logs describe-log-groups --log-group-name-prefix "$LEX_UI_LOG_GROUP" --query "logGroups[?logGroupName=='${LEX_UI_LOG_GROUP}'].logGroupName | [0]" --output text | grep -qv '^None$'; then EXISTING_LEX_UI_LOG_GROUP_NAME="$LEX_UI_LOG_GROUP"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_LOG_GROUP_NAME:-}" ]] && aws_cmd logs describe-log-groups --log-group-name-prefix "$LEX_PUBLISH_LOG_GROUP" --query "logGroups[?logGroupName=='${LEX_PUBLISH_LOG_GROUP}'].logGroupName | [0]" --output text | grep -qv '^None$'; then EXISTING_LEX_PUBLISH_LOG_GROUP_NAME="$LEX_PUBLISH_LOG_GROUP"; fi
fi

# ------------------------------------------------------------
# Show the exact create/reuse plan.
# ------------------------------------------------------------
show_plan() {
    local value="$1" create_label="$2" reuse_label="$3"
    if [[ -n "$value" ]]; then echo "  $reuse_label: $value"; else echo "  $create_label"; fi
}

echo
echo "============================================================"
echo " PRE-DEPLOYMENT RESOURCE PLAN"
echo "============================================================"
echo "--- IVR Resources ---"
show_plan "$EXISTING_MIGRATION_BUCKET_NAME" "Migration bucket: CREATE" "Migration bucket: REUSE"
show_plan "$EXISTING_BACKUP_BUCKET_NAME" "Backup bucket: CREATE" "Backup bucket: REUSE"
show_plan "$EXISTING_ARTIFACT_BUCKET_NAME" "Artifact bucket: CREATE" "Artifact bucket: REUSE"
show_plan "$EXISTING_ENVIRONMENT_TABLE_NAME" "Environment table: CREATE" "Environment table: REUSE"
show_plan "$EXISTING_AUDIT_TABLE_NAME" "Audit table: CREATE" "Audit table: REUSE"
show_plan "$EXISTING_REPOSITORY_NAME" "CodeCommit repository: CREATE" "CodeCommit repository: REUSE"
show_plan "$EXISTING_UI_LAMBDA_ROLE_ARN" "UI Lambda role: CREATE" "UI Lambda role: REUSE"
show_plan "$EXISTING_UPDATE_LAMBDA_ROLE_ARN" "Update Lambda role: CREATE" "Update Lambda role: REUSE"
show_plan "$EXISTING_PIPELINE_ROLE_ARN" "Pipeline role: CREATE" "Pipeline role: REUSE"
show_plan "$EXISTING_UI_GC_LAMBDA_ARN" "UI-GC Lambda: CREATE" "UI-GC Lambda: REUSE"
show_plan "$EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN" "Update Lambda: CREATE" "Update Lambda: REUSE"
show_plan "$EXISTING_PIPELINE_NAME" "IVR CodePipeline: CREATE" "IVR CodePipeline: REUSE"
show_plan "$EXISTING_UI_GC_LOG_GROUP_NAME" "UI log group: CREATE" "UI log group: REUSE"
show_plan "$EXISTING_UPDATE_FLOW_LOG_GROUP_NAME" "Update log group: CREATE" "Update log group: REUSE"
echo "--- Lex Resources ---"
show_plan "$EXISTING_LEX_UI_BUCKET_NAME" "Lex UI bucket: CREATE" "Lex UI bucket: REUSE"
show_plan "$EXISTING_LEX_PUBLISH_BUCKET_NAME" "Lex publish bucket: CREATE" "Lex publish bucket: REUSE"
show_plan "$EXISTING_LEX_AUDIT_TABLE_NAME" "Lex audit table: CREATE" "Lex audit table: REUSE"
show_plan "$EXISTING_LEX_REPOSITORY_NAME" "Lex CodeCommit repo: CREATE" "Lex CodeCommit repo: REUSE"
show_plan "$EXISTING_LEX_UI_LAMBDA_ROLE_ARN" "Lex UI Lambda role: CREATE" "Lex UI Lambda role: REUSE"
show_plan "$EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN" "Lex Publish Lambda role: CREATE" "Lex Publish Lambda role: REUSE"
show_plan "$EXISTING_LEX_UI_LAMBDA_ARN" "Lex UI Lambda: CREATE" "Lex UI Lambda: REUSE"
show_plan "$EXISTING_LEX_PUBLISH_LAMBDA_ARN" "Lex Publish Lambda: CREATE" "Lex Publish Lambda: REUSE"
show_plan "$EXISTING_LEX_PIPELINE_NAME" "Lex CodePipeline: CREATE" "Lex CodePipeline: REUSE"
show_plan "$EXISTING_LEX_UI_LOG_GROUP_NAME" "Lex UI log group: CREATE" "Lex UI log group: REUSE"
show_plan "$EXISTING_LEX_PUBLISH_LOG_GROUP_NAME" "Lex Publish log group: CREATE" "Lex Publish log group: REUSE"
echo "--- Shared API Gateway & Frontend ---"
show_plan "$EXISTING_API_ID" "API Gateway: CREATE" "API Gateway: REUSE"
echo "  Frontend infrastructure: ${DEPLOY_FRONTEND:-false}"
echo "============================================================"

if [[ "$ROOT_STACK_EXISTS" == "true" ]]; then
    warn "Root stack already exists. Existing-resource discovery was skipped. CloudFormation remains the owner of the existing stack resources."
fi

if [[ -n "${EXISTING_UI_LAMBDA_ROLE_ARN:-}" || -n "${EXISTING_UPDATE_LAMBDA_ROLE_ARN:-}" || -n "${EXISTING_PIPELINE_ROLE_ARN:-}" || -n "${EXISTING_LEX_UI_LAMBDA_ROLE_ARN:-}" || -n "${EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN:-}" ]]; then
    warn "One or more IAM roles are being reused. CloudFormation will not replace those roles; verify that the existing roles already contain the permissions required by this application."
fi

if [[ -n "${EXISTING_API_ID:-}" ]]; then
    warn "An existing API Gateway ID is being reused. Verify the existing API already exposes the required routes or configure existing resource IDs."
fi

if [[ "${CONFIRM_BEFORE_DEPLOY:-true}" == "true" && -t 0 ]]; then
    read -r -p "Continue with this deployment? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { warn "Deployment cancelled."; exit 0; }
fi

# ------------------------------------------------------------
# Package Lambdas.
# ------------------------------------------------------------
package_lambda() {
    local source_dir="$1"
    local package_name="$2"
    local package_path="$PACKAGE_DIR/$package_name"
    rm -f "$package_path"
    (cd "$source_dir" && zip -qr "$package_path" .)
    [[ -f "$package_path" ]] || die "Failed to create $package_path"
    success "Created $package_path"
}

if [[ "${PACKAGE_LAMBDAS:-true}" == "true" ]]; then
    package_lambda "$UI_GC_SOURCE_PATH" "$UI_GC_PACKAGE_NAME"
    package_lambda "$UPDATE_CONTACT_FLOW_SOURCE_PATH" "$UPDATE_CONTACT_FLOW_PACKAGE_NAME"
    package_lambda "$LEX_UI_SOURCE_PATH" "$LEX_UI_PACKAGE_NAME"
    package_lambda "$LEX_PUBLISH_SOURCE_PATH" "$LEX_PUBLISH_PACKAGE_NAME"

    aws_cmd s3 cp "$PACKAGE_DIR/$UI_GC_PACKAGE_NAME" "s3://$DEPLOYMENT_BUCKET/$UI_GC_S3_KEY"
    aws_cmd s3 cp "$PACKAGE_DIR/$UPDATE_CONTACT_FLOW_PACKAGE_NAME" "s3://$DEPLOYMENT_BUCKET/$UPDATE_CONTACT_FLOW_S3_KEY"
    aws_cmd s3 cp "$PACKAGE_DIR/$LEX_UI_PACKAGE_NAME" "s3://$DEPLOYMENT_BUCKET/$LEX_UI_S3_KEY"
    aws_cmd s3 cp "$PACKAGE_DIR/$LEX_PUBLISH_PACKAGE_NAME" "s3://$DEPLOYMENT_BUCKET/$LEX_PUBLISH_S3_KEY"
    success "Lambda packages uploaded."
fi

# ------------------------------------------------------------
# Upload CloudFormation templates.
# ------------------------------------------------------------
if [[ "${UPLOAD_CLOUDFORMATION_TEMPLATES:-true}" == "true" ]]; then
    log "Uploading nested templates to s3://$DEPLOYMENT_BUCKET/$TEMPLATE_S3_PREFIX/ ..."
    aws_cmd s3 sync "$TEMPLATE_DIR_PATH" "s3://$DEPLOYMENT_BUCKET/$TEMPLATE_S3_PREFIX/" --delete
    success "Nested templates uploaded."
fi

log "Validating root template..."
aws_cmd cloudformation validate-template --template-body "file://$ROOT_TEMPLATE_PATH" >/dev/null
success "root.yaml passed CloudFormation validation."

# ------------------------------------------------------------
# Root parameters.
# ------------------------------------------------------------
CFN_PARAMETERS=(
    "Environment=$ENVIRONMENT"
    "ProjectName=$PROJECT_NAME"
    "TemplateBucketName=$DEPLOYMENT_BUCKET"
    "TemplateS3Prefix=$TEMPLATE_S3_PREFIX"
    "LambdaCodeS3Bucket=$DEPLOYMENT_BUCKET"
    "LambdaCodeS3Prefix=lambda-src"
    "StorageBucketPrefix=$STORAGE_BUCKET_PREFIX"
    "ExistingMigrationBucketName=$EXISTING_MIGRATION_BUCKET_NAME"
    "ExistingBackupBucketName=$EXISTING_BACKUP_BUCKET_NAME"
    "ExistingArtifactBucketName=$EXISTING_ARTIFACT_BUCKET_NAME"
    "LexUiBucketName=$LEX_UI_BUCKET_NAME"
    "LexPublishBucketName=$LEX_PUBLISH_BUCKET_NAME"
    "ExistingLexUiBucketName=$EXISTING_LEX_UI_BUCKET_NAME"
    "ExistingLexPublishBucketName=$EXISTING_LEX_PUBLISH_BUCKET_NAME"
    "EnvironmentTableName=$ENVIRONMENT_TABLE_NAME"
    "AuditTableName=$AUDIT_TRAIL_TABLE_NAME"
    "ExistingEnvironmentTableName=$EXISTING_ENVIRONMENT_TABLE_NAME"
    "ExistingAuditTableName=$EXISTING_AUDIT_TABLE_NAME"
    "LexAuditTableName=$LEX_AUDIT_TABLE_NAME"
    "ExistingLexAuditTableName=$EXISTING_LEX_AUDIT_TABLE_NAME"
    "CodeCommitRepositoryName=$CODECOMMIT_REPOSITORY_NAME"
    "CodeCommitBranchName=$CODECOMMIT_BRANCH_NAME"
    "ExistingRepositoryName=$EXISTING_REPOSITORY_NAME"
    "LexRepositoryName=$LEX_CODECOMMIT_REPOSITORY_NAME"
    "LexRepositoryBranchName=$LEX_CODECOMMIT_BRANCH_NAME"
    "ExistingLexRepositoryName=$EXISTING_LEX_REPOSITORY_NAME"
    "UILambdaRoleName=$UI_LAMBDA_ROLE_NAME"
    "UpdateLambdaRoleName=$UPDATE_LAMBDA_ROLE_NAME"
    "PipelineRoleName=$PIPELINE_ROLE_NAME"
    "ExistingUILambdaRoleArn=$EXISTING_UI_LAMBDA_ROLE_ARN"
    "ExistingUpdateLambdaRoleArn=$EXISTING_UPDATE_LAMBDA_ROLE_ARN"
    "ExistingPipelineRoleArn=$EXISTING_PIPELINE_ROLE_ARN"
    "LexUILambdaRoleName=$LEX_UI_LAMBDA_ROLE_NAME"
    "LexPublishLambdaRoleName=$LEX_PUBLISH_LAMBDA_ROLE_NAME"
    "ExistingLexUILambdaRoleArn=$EXISTING_LEX_UI_LAMBDA_ROLE_ARN"
    "ExistingLexPublishLambdaRoleArn=$EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN"
    "LexBotImportRoleArn=$LEX_BOT_IMPORT_ROLE_ARN"
    "UiGcLambdaName=$UI_GC_LAMBDA_NAME"
    "UiGcLambdaMemory=$UI_GC_LAMBDA_MEMORY"
    "UiGcLambdaTimeout=$UI_GC_LAMBDA_TIMEOUT"
    "ExistingUiGcLambdaArn=$EXISTING_UI_GC_LAMBDA_ARN"
    "UpdateContactFlowLambdaName=$UPDATE_CONTACT_FLOW_LAMBDA_NAME"
    "UpdateContactFlowLambdaMemory=$UPDATE_CONTACT_FLOW_LAMBDA_MEMORY"
    "UpdateContactFlowLambdaTimeout=$UPDATE_CONTACT_FLOW_LAMBDA_TIMEOUT"
    "ExistingUpdateContactFlowLambdaArn=$EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN"
    "LexUILambdaName=$LEX_UI_LAMBDA_NAME"
    "ExistingLexUILambdaArn=$EXISTING_LEX_UI_LAMBDA_ARN"
    "LexPublishLambdaName=$LEX_PUBLISH_LAMBDA_NAME"
    "ExistingLexPublishLambdaArn=$EXISTING_LEX_PUBLISH_LAMBDA_ARN"
    "ApiName=$API_NAME"
    "ApiStageName=$API_STAGE_NAME"
    "ExistingApiId=$EXISTING_API_ID"
    "ExistingApiRootResourceId=$EXISTING_API_ROOT_RESOURCE_ID"
    "ExistingLexResourceId=$EXISTING_LEX_RESOURCE_ID"
    "PipelineName=$PIPELINE_NAME"
    "ExistingPipelineName=$EXISTING_PIPELINE_NAME"
    "LexPipelineName=$LEX_PIPELINE_NAME"
    "ExistingLexPipelineName=$EXISTING_LEX_PIPELINE_NAME"
    "LogRetentionDays=$LOG_RETENTION_DAYS"
    "ExistingUIGCLogGroupName=$EXISTING_UI_GC_LOG_GROUP_NAME"
    "ExistingUpdateFlowLogGroupName=$EXISTING_UPDATE_FLOW_LOG_GROUP_NAME"
    "ExistingLexUILogGroupName=$EXISTING_LEX_UI_LOG_GROUP_NAME"
    "ExistingLexPublishLogGroupName=$EXISTING_LEX_PUBLISH_LOG_GROUP_NAME"
    "DeployFrontendInfrastructure=${DEPLOY_FRONTEND:-false}"
    "FrontendBucketPrefix=${FRONTEND_BUCKET_PREFIX:-devops-connect-frontend}"
    "FrontendDefaultRootObject=${FRONTEND_DEFAULT_ROOT_OBJECT:-index.html}"
    "CloudFrontPriceClass=${CLOUDFRONT_PRICE_CLASS:-PriceClass_100}"
    "ExistingFrontendBucketName=${EXISTING_FRONTEND_BUCKET_NAME:-}"
    "ExistingCloudFrontDistributionId=${EXISTING_CLOUDFRONT_DISTRIBUTION_ID:-}"
    "ExistingCloudFrontDomainName=${EXISTING_CLOUDFRONT_DOMAIN_NAME:-}"
)

log "Starting CloudFormation deployment..."
aws_cmd cloudformation deploy \
    --template-file "$ROOT_TEMPLATE_PATH" \
    --stack-name "$STACK_NAME" \
    --parameter-overrides "${CFN_PARAMETERS[@]}" \
    --capabilities "$CFN_CAPABILITIES" \
    --no-fail-on-empty-changeset

# ------------------------------------------------------------
# Update existing Lambda functions in place.
# ------------------------------------------------------------
get_stack_output() {
    aws_cmd cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" \
        --output text 2>/dev/null || true
}

update_reused_lambda_if_present() {
    local fn_arn="$1"
    local s3_key="$2"
    local fn_desc="$3"
    shift 3
    local env_vars=("$@")

    if [[ -z "$fn_arn" || "$fn_arn" == "None" ]]; then
        return 0
    fi

    log "Updating reused Lambda in place ($fn_desc): $fn_arn"
    aws_cmd lambda update-function-code \
        --function-name "$fn_arn" \
        --s3-bucket "$DEPLOYMENT_BUCKET" \
        --s3-key "$s3_key" >/dev/null

    aws_cmd lambda wait function-updated --function-name "$fn_arn"

    local env_kv=()
    for item in "${env_vars[@]}"; do
        env_kv+=("$item")
    done
    local env_str
    env_str="$(IFS=,; echo "${env_kv[*]}")"

    aws_cmd lambda update-function-configuration \
        --function-name "$fn_arn" \
        --environment "Variables={$env_str}" >/dev/null

    aws_cmd lambda wait function-updated --function-name "$fn_arn"
    success "Updated reused Lambda: $fn_desc"
}

if [[ -n "${EXISTING_UI_GC_LAMBDA_ARN:-}" ]]; then
    MIGRATION_BUCKET_NAME="$(get_stack_output MigrationBucketName)"
    BACKUP_BUCKET_NAME="$(get_stack_output BackupBucketName)"
    ENVT_TABLE="$(get_stack_output EnvironmentTableName)"
    AUDIT_TABLE="$(get_stack_output AuditTrailTableName)"

    update_reused_lambda_if_present \
        "$EXISTING_UI_GC_LAMBDA_ARN" \
        "$UI_GC_S3_KEY" \
        "UI-GC" \
        "UI_GC_BUCKET_NAME=$MIGRATION_BUCKET_NAME" \
        "DATA_BKP_BUCKET_NAME=$BACKUP_BUCKET_NAME" \
        "ENVT_TABLE_NAME=$ENVT_TABLE" \
        "AUDIT_TABLE_NAME=$AUDIT_TABLE" \
        "CODECOMMIT_REPO_NAME=$CODECOMMIT_REPOSITORY_NAME" \
        "CODECOMMIT_BRANCH_NAME=$CODECOMMIT_BRANCH_NAME"
fi

if [[ -n "${EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN:-}" ]]; then
    BACKUP_BUCKET_NAME="$(get_stack_output BackupBucketName)"
    AUDIT_TABLE="$(get_stack_output AuditTrailTableName)"

    update_reused_lambda_if_present \
        "$EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN" \
        "$UPDATE_CONTACT_FLOW_S3_KEY" \
        "UpdateContactFlow" \
        "AUDIT_TABLE_NAME=$AUDIT_TABLE" \
        "CODECOMMIT_REPO_NAME=$CODECOMMIT_REPOSITORY_NAME" \
        "DATA_BKP_BUCKET_NAME=$BACKUP_BUCKET_NAME"
fi

if [[ -n "${EXISTING_LEX_UI_LAMBDA_ARN:-}" ]]; then
    LEX_UI_BUCKET="$(get_stack_output LexUiBucketName)"
    LEX_AUDIT_TABLE="$(get_stack_output LexAuditTableName)"

    update_reused_lambda_if_present \
        "$EXISTING_LEX_UI_LAMBDA_ARN" \
        "$LEX_UI_S3_KEY" \
        "Lex-UI" \
        "LEX_UI_BUCKET_NAME=$LEX_UI_BUCKET" \
        "CODECOMMIT_REPO_NAME=$LEX_CODECOMMIT_REPOSITORY_NAME" \
        "CODECOMMIT_BRANCH_NAME=$LEX_CODECOMMIT_BRANCH_NAME" \
        "LEX_AUDIT_TABLE_NAME=$LEX_AUDIT_TABLE"
fi

if [[ -n "${EXISTING_LEX_PUBLISH_LAMBDA_ARN:-}" ]]; then
    LEX_PUBLISH_BUCKET="$(get_stack_output LexPublishBucketName)"
    LEX_AUDIT_TABLE="$(get_stack_output LexAuditTableName)"

    update_reused_lambda_if_present \
        "$EXISTING_LEX_PUBLISH_LAMBDA_ARN" \
        "$LEX_PUBLISH_S3_KEY" \
        "Lex-Publish" \
        "CODECOMMIT_REPO_NAME=$LEX_CODECOMMIT_REPOSITORY_NAME" \
        "CODECOMMIT_BRANCH_NAME=$LEX_CODECOMMIT_BRANCH_NAME" \
        "SOURCE_S3_BUCKET_NAME=$LEX_PUBLISH_BUCKET_NAME" \
        "LEX_AUDIT_TABLE_NAME=$LEX_AUDIT_TABLE"
fi

# ------------------------------------------------------------
# Print outputs.
# ------------------------------------------------------------
if [[ "${PRINT_STACK_OUTPUTS:-true}" == "true" ]]; then
    echo
    echo "============================================================"
    echo " CLOUDFORMATION STACK OUTPUTS"
    echo "============================================================"
    aws_cmd cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue,Description:Description}" \
        --output table
    echo "============================================================"
fi

success "Deployment finished successfully."
