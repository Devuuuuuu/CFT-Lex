#!/usr/bin/env bash

# ============================================================
# ConnectOps - Safe Deployment Script (IVR & Lex Migration)
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

The script performs a preflight check, packages Lambdas, uploads templates,
reuses matching resources on new deployment, and safely deploys root.yaml.
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
    ROOT_TEMPLATE TEMPLATE_DIR TEMPLATE_S3_PREFIX
    DEPLOYMENT_BUCKET_PREFIX STORAGE_BUCKET_PREFIX
    ENVIRONMENT_TABLE_NAME AUDIT_TRAIL_TABLE_NAME
    CODECOMMIT_REPOSITORY_NAME CODECOMMIT_BRANCH_NAME
    UI_LAMBDA_ROLE_NAME UPDATE_LAMBDA_ROLE_NAME PIPELINE_ROLE_NAME
    UI_GC_LAMBDA_NAME UPDATE_CONTACT_FLOW_LAMBDA_NAME
    API_NAME API_STAGE_NAME PIPELINE_NAME LOG_RETENTION_DAYS
)
for v in "${required_vars[@]}"; do
    [[ -n "${!v:-}" ]] || die "$v is required in deploy.config"
done

ROOT_TEMPLATE_PATH="$SCRIPT_DIR/$ROOT_TEMPLATE"
TEMPLATE_DIR_PATH="$SCRIPT_DIR/$TEMPLATE_DIR"
UI_GC_SOURCE_PATH="$SCRIPT_DIR/${UI_GC_SOURCE_DIR:-lambda-src/ui-gc}"
UPDATE_CONTACT_FLOW_SOURCE_PATH="$SCRIPT_DIR/${UPDATE_CONTACT_FLOW_SOURCE_DIR:-lambda-src/update-contact-flow}"
LEX_UI_SOURCE_PATH="$SCRIPT_DIR/${LEX_UI_SOURCE_DIR:-lambda-src/lex-ui}"
LEX_PUBLISH_SOURCE_PATH="$SCRIPT_DIR/${LEX_PUBLISH_SOURCE_DIR:-lambda-src/lex-publish}"
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

AWS_ACCOUNT_ID="$(aws_cmd sts get-caller-identity --query Account --output text)"
AWS_ARN="$(aws_cmd sts get-caller-identity --query Arn --output text)"
[[ "$AWS_ACCOUNT_ID" != "None" ]] || die "Unable to determine AWS account."
success "AWS account: $AWS_ACCOUNT_ID"
log "AWS identity: $AWS_ARN"
log "AWS region: $AWS_REGION"

# ------------------------------------------------------------
# Deployment bucket
# ------------------------------------------------------------
if [[ -z "${DEPLOYMENT_BUCKET:-}" ]]; then
    DEPLOYMENT_BUCKET="${DEPLOYMENT_BUCKET_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
fi
DEPLOYMENT_BUCKET="$(echo "$DEPLOYMENT_BUCKET" | tr '[:upper:]' '[:lower:]')"

bucket_exists() { aws_cmd s3api head-bucket --bucket "$1" >/dev/null 2>&1; }

if bucket_exists "$DEPLOYMENT_BUCKET"; then
    success "Deployment bucket exists: $DEPLOYMENT_BUCKET"
else
    log "Creating deployment bucket: $DEPLOYMENT_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws_cmd s3api create-bucket --bucket "$DEPLOYMENT_BUCKET"
    else
        aws_cmd s3api create-bucket --bucket "$DEPLOYMENT_BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION"
    fi
    aws_cmd s3api put-bucket-encryption --bucket "$DEPLOYMENT_BUCKET" --server-side-encryption-configuration 'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]'
    aws_cmd s3api put-public-access-block --bucket "$DEPLOYMENT_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    success "Deployment bucket created."
fi

# ------------------------------------------------------------
# Detect whether root stack already exists.
# ------------------------------------------------------------
ROOT_STACK_EXISTS="false"
if aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    ROOT_STACK_EXISTS="true"
fi

if [[ "$ROOT_STACK_EXISTS" == "true" ]]; then
    log "Root stack $STACK_NAME exists. Restoring resource ownership from existing stack..."

    get_stack_parameter() {
        aws_cmd cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue | [0]" \
            --output text 2>/dev/null || true
    }

    value="$(get_stack_parameter ExistingMigrationBucketName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_MIGRATION_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingBackupBucketName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_BACKUP_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingArtifactBucketName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_ARTIFACT_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingLexUiBucketName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_UI_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingLexPublishBucketName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_PUBLISH_BUCKET_NAME="$value"
    value="$(get_stack_parameter ExistingEnvironmentTableName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_ENVIRONMENT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingAuditTableName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_AUDIT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingLexAuditTableName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_AUDIT_TABLE_NAME="$value"
    value="$(get_stack_parameter ExistingRepositoryName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_REPOSITORY_NAME="$value"
    value="$(get_stack_parameter ExistingLexRepositoryName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_REPOSITORY_NAME="$value"
    value="$(get_stack_parameter ExistingUILambdaRoleArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_UI_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingUpdateLambdaRoleArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_UPDATE_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingPipelineRoleArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_PIPELINE_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingLexUILambdaRoleArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_UI_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingLexPublishLambdaRoleArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN="$value"
    value="$(get_stack_parameter ExistingUiGcLambdaArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_UI_GC_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingUpdateContactFlowLambdaArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingLexUILambdaArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_UI_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingLexPublishLambdaArn)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_PUBLISH_LAMBDA_ARN="$value"
    value="$(get_stack_parameter ExistingApiId)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_API_ID="$value"
    value="$(get_stack_parameter ExistingPipelineName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_PIPELINE_NAME="$value"
    value="$(get_stack_parameter ExistingLexPipelineName)"; [[ -n "$value" && "$value" != "None" ]] && EXISTING_LEX_PIPELINE_NAME="$value"
fi

if [[ "$ROOT_STACK_EXISTS" == "false" && "${AUTO_REUSE_EXISTING:-true}" == "true" ]]; then
    log "No existing root stack found. Running existing-resource discovery..."

    STORAGE_MIGRATION_EXPECTED="${STORAGE_BUCKET_PREFIX}-ui-gc-${AWS_ACCOUNT_ID}"
    STORAGE_BACKUP_EXPECTED="${STORAGE_BUCKET_PREFIX}-backup-${AWS_ACCOUNT_ID}"
    STORAGE_ARTIFACT_EXPECTED="${STORAGE_BUCKET_PREFIX}-artifacts-${AWS_ACCOUNT_ID}"

    if [[ -z "${EXISTING_MIGRATION_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_MIGRATION_EXPECTED"; then EXISTING_MIGRATION_BUCKET_NAME="$STORAGE_MIGRATION_EXPECTED"; fi
    if [[ -z "${EXISTING_BACKUP_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_BACKUP_EXPECTED"; then EXISTING_BACKUP_BUCKET_NAME="$STORAGE_BACKUP_EXPECTED"; fi
    if [[ -z "${EXISTING_ARTIFACT_BUCKET_NAME:-}" ]] && bucket_exists "$STORAGE_ARTIFACT_EXPECTED"; then EXISTING_ARTIFACT_BUCKET_NAME="$STORAGE_ARTIFACT_EXPECTED"; fi
    if [[ -z "${EXISTING_LEX_UI_BUCKET_NAME:-}" ]] && bucket_exists "${LEX_UI_BUCKET_NAME:-devops-lex-ui-files}"; then EXISTING_LEX_UI_BUCKET_NAME="${LEX_UI_BUCKET_NAME:-devops-lex-ui-files}"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_BUCKET_NAME:-}" ]] && bucket_exists "${LEX_PUBLISH_BUCKET_NAME:-devops-lex-scm-bkp-s3}"; then EXISTING_LEX_PUBLISH_BUCKET_NAME="${LEX_PUBLISH_BUCKET_NAME:-devops-lex-scm-bkp-s3}"; fi

    if [[ -z "${EXISTING_ENVIRONMENT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "$ENVIRONMENT_TABLE_NAME" >/dev/null 2>&1; then EXISTING_ENVIRONMENT_TABLE_NAME="$ENVIRONMENT_TABLE_NAME"; fi
    if [[ -z "${EXISTING_AUDIT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "$AUDIT_TRAIL_TABLE_NAME" >/dev/null 2>&1; then EXISTING_AUDIT_TABLE_NAME="$AUDIT_TRAIL_TABLE_NAME"; fi
    if [[ -z "${EXISTING_LEX_AUDIT_TABLE_NAME:-}" ]] && aws_cmd dynamodb describe-table --table-name "${LEX_AUDIT_TABLE_NAME:-Devops-Lex-AuditTrail}" >/dev/null 2>&1; then EXISTING_LEX_AUDIT_TABLE_NAME="${LEX_AUDIT_TABLE_NAME:-Devops-Lex-AuditTrail}"; fi

    if [[ -z "${EXISTING_REPOSITORY_NAME:-}" ]] && aws_cmd codecommit get-repository --repository-name "$CODECOMMIT_REPOSITORY_NAME" >/dev/null 2>&1; then EXISTING_REPOSITORY_NAME="$CODECOMMIT_REPOSITORY_NAME"; fi
    if [[ -z "${EXISTING_LEX_REPOSITORY_NAME:-}" ]] && aws_cmd codecommit get-repository --repository-name "${LEX_REPOSITORY_NAME:-Devops-Lex-SCM-BKP}" >/dev/null 2>&1; then EXISTING_LEX_REPOSITORY_NAME="${LEX_REPOSITORY_NAME:-Devops-Lex-SCM-BKP}"; fi

    if [[ -z "${EXISTING_UI_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$UI_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_UI_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$UI_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_UPDATE_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$UPDATE_LAMBDA_ROLE_NAME" >/dev/null 2>&1; then EXISTING_UPDATE_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "$UPDATE_LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_PIPELINE_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "$PIPELINE_ROLE_NAME" >/dev/null 2>&1; then EXISTING_PIPELINE_ROLE_ARN="$(aws_cmd iam get-role --role-name "$PIPELINE_ROLE_NAME" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_UI_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "${LEX_UI_LAMBDA_ROLE_NAME:-DevOps-Lex-UI-Lambda-Role}" >/dev/null 2>&1; then EXISTING_LEX_UI_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "${LEX_UI_LAMBDA_ROLE_NAME:-DevOps-Lex-UI-Lambda-Role}" --query 'Role.Arn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN:-}" ]] && aws_cmd iam get-role --role-name "${LEX_PUBLISH_LAMBDA_ROLE_NAME:-DevOps-Lex-Publish-Lambda-Role}" >/dev/null 2>&1; then EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN="$(aws_cmd iam get-role --role-name "${LEX_PUBLISH_LAMBDA_ROLE_NAME:-DevOps-Lex-Publish-Lambda-Role}" --query 'Role.Arn' --output text)"; fi

    if [[ -z "${EXISTING_UI_GC_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$UI_GC_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_UI_GC_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$UI_GC_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "$UPDATE_CONTACT_FLOW_LAMBDA_NAME" >/dev/null 2>&1; then EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "$UPDATE_CONTACT_FLOW_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_UI_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "${LEX_UI_LAMBDA_NAME:-Devops-Lex-UI}" >/dev/null 2>&1; then EXISTING_LEX_UI_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "${LEX_UI_LAMBDA_NAME:-Devops-Lex-UI}" --query 'Configuration.FunctionArn' --output text)"; fi
    if [[ -z "${EXISTING_LEX_PUBLISH_LAMBDA_ARN:-}" ]] && aws_cmd lambda get-function --function-name "${LEX_PUBLISH_LAMBDA_NAME:-Devops-Lex-PublishLexZip-BKP}" >/dev/null 2>&1; then EXISTING_LEX_PUBLISH_LAMBDA_ARN="$(aws_cmd lambda get-function --function-name "${LEX_PUBLISH_LAMBDA_NAME:-Devops-Lex-PublishLexZip-BKP}" --query 'Configuration.FunctionArn' --output text)"; fi

    if [[ -z "${EXISTING_API_ID:-}" ]]; then
        EXISTING_API_ID="$(aws_cmd apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id | [0]" --output text 2>/dev/null || true)"
        [[ "$EXISTING_API_ID" == "None" ]] && EXISTING_API_ID=""
    fi

    if [[ -z "${EXISTING_PIPELINE_NAME:-}" ]] && aws_cmd codepipeline get-pipeline --name "$PIPELINE_NAME" >/dev/null 2>&1; then EXISTING_PIPELINE_NAME="$PIPELINE_NAME"; fi
    if [[ -z "${EXISTING_LEX_PIPELINE_NAME:-}" ]] && aws_cmd codepipeline get-pipeline --name "${LEX_PIPELINE_NAME:-Devops-Lex-Pipeline-BKP}" >/dev/null 2>&1; then EXISTING_LEX_PIPELINE_NAME="${LEX_PIPELINE_NAME:-Devops-Lex-Pipeline-BKP}"; fi
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
show_plan "${EXISTING_MIGRATION_BUCKET_NAME:-}" "Migration bucket: CREATE" "Migration bucket: REUSE"
show_plan "${EXISTING_BACKUP_BUCKET_NAME:-}" "Backup bucket: CREATE" "Backup bucket: REUSE"
show_plan "${EXISTING_ARTIFACT_BUCKET_NAME:-}" "Artifact bucket: CREATE" "Artifact bucket: REUSE"
show_plan "${EXISTING_LEX_UI_BUCKET_NAME:-}" "Lex UI bucket: CREATE" "Lex UI bucket: REUSE"
show_plan "${EXISTING_LEX_PUBLISH_BUCKET_NAME:-}" "Lex Publish bucket: CREATE" "Lex Publish bucket: REUSE"
show_plan "${EXISTING_ENVIRONMENT_TABLE_NAME:-}" "Environment table: CREATE" "Environment table: REUSE"
show_plan "${EXISTING_AUDIT_TABLE_NAME:-}" "Audit table: CREATE" "Audit table: REUSE"
show_plan "${EXISTING_LEX_AUDIT_TABLE_NAME:-}" "Lex Audit table: CREATE" "Lex Audit table: REUSE"
show_plan "${EXISTING_REPOSITORY_NAME:-}" "IVR CodeCommit: CREATE" "IVR CodeCommit: REUSE"
show_plan "${EXISTING_LEX_REPOSITORY_NAME:-}" "Lex CodeCommit: CREATE" "Lex CodeCommit: REUSE"
show_plan "${EXISTING_UI_LAMBDA_ROLE_ARN:-}" "UI Lambda role: CREATE" "UI Lambda role: REUSE"
show_plan "${EXISTING_UPDATE_LAMBDA_ROLE_ARN:-}" "Update Lambda role: CREATE" "Update Lambda role: REUSE"
show_plan "${EXISTING_PIPELINE_ROLE_ARN:-}" "Pipeline role: CREATE" "Pipeline role: REUSE"
show_plan "${EXISTING_LEX_UI_LAMBDA_ROLE_ARN:-}" "Lex UI Lambda role: CREATE" "Lex UI Lambda role: REUSE"
show_plan "${EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN:-}" "Lex Publish Lambda role: CREATE" "Lex Publish Lambda role: REUSE"
show_plan "${EXISTING_UI_GC_LAMBDA_ARN:-}" "UI-GC Lambda: CREATE" "UI-GC Lambda: REUSE"
show_plan "${EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN:-}" "Update Lambda: CREATE" "Update Lambda: REUSE"
show_plan "${EXISTING_LEX_UI_LAMBDA_ARN:-}" "Lex UI Lambda: CREATE" "Lex UI Lambda: REUSE"
show_plan "${EXISTING_LEX_PUBLISH_LAMBDA_ARN:-}" "Lex Publish Lambda: CREATE" "Lex Publish Lambda: REUSE"
show_plan "${EXISTING_API_ID:-}" "API Gateway: CREATE" "API Gateway: REUSE"
show_plan "${EXISTING_PIPELINE_NAME:-}" "IVR Pipeline: CREATE" "IVR Pipeline: REUSE"
show_plan "${EXISTING_LEX_PIPELINE_NAME:-}" "Lex Pipeline: CREATE" "Lex Pipeline: REUSE"
echo "  Frontend infrastructure: ${DEPLOY_FRONTEND:-false}"
echo "============================================================"

if [[ "$ROOT_STACK_EXISTS" == "true" ]]; then
    warn "Root stack already exists. Existing-resource discovery was skipped. CloudFormation remains the owner of the existing stack resources."
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
    local req_file="$source_dir/requirements.txt"
    rm -f "$package_path"
    local temp_build="$BUILD_DIR/build_${package_name%.zip}"
    rm -rf "$temp_build"
    mkdir -p "$temp_build"
    cp -R "$source_dir"/* "$temp_build"/ 2>/dev/null || true
    if [[ -f "$req_file" ]] && grep -qvE '^\s*#|^\s*$' "$req_file"; then
        if command -v pip3 >/dev/null 2>&1; then
            pip3 install -q -t "$temp_build" -r "$req_file" --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 2>/dev/null || pip3 install -q -t "$temp_build" -r "$req_file" 2>/dev/null || true
        fi
    fi
    (cd "$temp_build" && zip -qr "$package_path" .)
    [[ -f "$package_path" ]] || die "Failed to create $package_path"
    success "Created $package_path"
}

if [[ "${PACKAGE_LAMBDAS:-true}" == "true" ]]; then
    package_lambda "$UI_GC_SOURCE_PATH" "${UI_GC_PACKAGE_NAME:-ui-gc.zip}"
    package_lambda "$UPDATE_CONTACT_FLOW_SOURCE_PATH" "${UPDATE_CONTACT_FLOW_PACKAGE_NAME:-update-contact-flow.zip}"
    package_lambda "$LEX_UI_SOURCE_PATH" "${LEX_UI_PACKAGE_NAME:-lex-ui.zip}"
    package_lambda "$LEX_PUBLISH_SOURCE_PATH" "${LEX_PUBLISH_PACKAGE_NAME:-lex-publish.zip}"

    aws_cmd s3 cp "$PACKAGE_DIR/${UI_GC_PACKAGE_NAME:-ui-gc.zip}" "s3://$DEPLOYMENT_BUCKET/${UI_GC_S3_KEY:-lambda-src/ui-gc.zip}"
    aws_cmd s3 cp "$PACKAGE_DIR/${UPDATE_CONTACT_FLOW_PACKAGE_NAME:-update-contact-flow.zip}" "s3://$DEPLOYMENT_BUCKET/${UPDATE_CONTACT_FLOW_S3_KEY:-lambda-src/update-contact-flow.zip}"
    aws_cmd s3 cp "$PACKAGE_DIR/${LEX_UI_PACKAGE_NAME:-lex-ui.zip}" "s3://$DEPLOYMENT_BUCKET/${LEX_UI_S3_KEY:-lambda-src/lex-ui.zip}"
    aws_cmd s3 cp "$PACKAGE_DIR/${LEX_PUBLISH_PACKAGE_NAME:-lex-publish.zip}" "s3://$DEPLOYMENT_BUCKET/${LEX_PUBLISH_S3_KEY:-lambda-src/lex-publish.zip}"
    success "Lambda packages uploaded."
fi

# ------------------------------------------------------------
# Upload nested templates.
# ------------------------------------------------------------
if [[ "${UPLOAD_CLOUDFORMATION_TEMPLATES:-true}" == "true" ]]; then
    shopt -s nullglob
    template_files=("$TEMPLATE_DIR_PATH"/*.yaml)
    shopt -u nullglob
    [[ ${#template_files[@]} -gt 0 ]] || die "No CloudFormation templates found."
    for template_file in "${template_files[@]}"; do
        template_name="$(basename "$template_file")"
        aws_cmd s3 cp "$template_file" "s3://$DEPLOYMENT_BUCKET/$TEMPLATE_S3_PREFIX/$template_name"
    done
    success "CloudFormation templates uploaded."
fi

# ------------------------------------------------------------
# Validate root template.
# ------------------------------------------------------------
aws_cmd cloudformation validate-template --template-body "file://$ROOT_TEMPLATE_PATH" >/dev/null 2>&1 || true
success "Validation complete."

# ------------------------------------------------------------
# Root parameters.
# ------------------------------------------------------------
CFN_PARAMETERS=(
    "Environment=$ENVIRONMENT"
    "ProjectName=$PROJECT_NAME"
    "TemplateBucketName=$DEPLOYMENT_BUCKET"
    "TemplateS3Prefix=$TEMPLATE_S3_PREFIX"
    "LambdaCodeS3Bucket=$DEPLOYMENT_BUCKET"
    "LambdaCodeS3Prefix=${LAMBDA_CODE_S3_PREFIX:-lambda-src}"
    "StorageBucketPrefix=$STORAGE_BUCKET_PREFIX"
    "ExistingMigrationBucketName=${EXISTING_MIGRATION_BUCKET_NAME:-}"
    "ExistingBackupBucketName=${EXISTING_BACKUP_BUCKET_NAME:-}"
    "ExistingArtifactBucketName=${EXISTING_ARTIFACT_BUCKET_NAME:-}"
    "LexUiBucketName=${LEX_UI_BUCKET_NAME:-devops-lex-ui-files}"
    "LexPublishBucketName=${LEX_PUBLISH_BUCKET_NAME:-devops-lex-scm-bkp-s3}"
    "ExistingLexUiBucketName=${EXISTING_LEX_UI_BUCKET_NAME:-}"
    "ExistingLexPublishBucketName=${EXISTING_LEX_PUBLISH_BUCKET_NAME:-}"
    "EnvironmentTableName=$ENVIRONMENT_TABLE_NAME"
    "AuditTableName=$AUDIT_TRAIL_TABLE_NAME"
    "ExistingEnvironmentTableName=${EXISTING_ENVIRONMENT_TABLE_NAME:-}"
    "ExistingAuditTableName=${EXISTING_AUDIT_TABLE_NAME:-}"
    "LexAuditTableName=${LEX_AUDIT_TABLE_NAME:-Devops-Lex-AuditTrail}"
    "ExistingLexAuditTableName=${EXISTING_LEX_AUDIT_TABLE_NAME:-}"
    "CodeCommitRepositoryName=$CODECOMMIT_REPOSITORY_NAME"
    "CodeCommitBranchName=$CODECOMMIT_BRANCH_NAME"
    "ExistingRepositoryName=${EXISTING_REPOSITORY_NAME:-}"
    "LexRepositoryName=${LEX_REPOSITORY_NAME:-Devops-Lex-SCM-BKP}"
    "LexRepositoryBranchName=${LEX_REPOSITORY_BRANCH_NAME:-master}"
    "ExistingLexRepositoryName=${EXISTING_LEX_REPOSITORY_NAME:-}"
    "UILambdaRoleName=$UI_LAMBDA_ROLE_NAME"
    "UpdateLambdaRoleName=$UPDATE_LAMBDA_ROLE_NAME"
    "PipelineRoleName=$PIPELINE_ROLE_NAME"
    "ExistingUILambdaRoleArn=${EXISTING_UI_LAMBDA_ROLE_ARN:-}"
    "ExistingUpdateLambdaRoleArn=${EXISTING_UPDATE_LAMBDA_ROLE_ARN:-}"
    "ExistingPipelineRoleArn=${EXISTING_PIPELINE_ROLE_ARN:-}"
    "LexUILambdaRoleName=${LEX_UI_LAMBDA_ROLE_NAME:-DevOps-Lex-UI-Lambda-Role}"
    "LexPublishLambdaRoleName=${LEX_PUBLISH_LAMBDA_ROLE_NAME:-DevOps-Lex-Publish-Lambda-Role}"
    "ExistingLexUILambdaRoleArn=${EXISTING_LEX_UI_LAMBDA_ROLE_ARN:-}"
    "ExistingLexPublishLambdaRoleArn=${EXISTING_LEX_PUBLISH_LAMBDA_ROLE_ARN:-}"
    "LexBotImportRoleArn=${LEX_BOT_IMPORT_ROLE_ARN:-}"
    "UiGcLambdaName=$UI_GC_LAMBDA_NAME"
    "UiGcLambdaMemory=${UI_GC_LAMBDA_MEMORY:-128}"
    "UiGcLambdaTimeout=${UI_GC_LAMBDA_TIMEOUT:-900}"
    "ExistingUiGcLambdaArn=${EXISTING_UI_GC_LAMBDA_ARN:-}"
    "UpdateContactFlowLambdaName=$UPDATE_CONTACT_FLOW_LAMBDA_NAME"
    "UpdateContactFlowLambdaMemory=${UPDATE_CONTACT_FLOW_LAMBDA_MEMORY:-128}"
    "UpdateContactFlowLambdaTimeout=${UPDATE_CONTACT_FLOW_LAMBDA_TIMEOUT:-300}"
    "ExistingUpdateContactFlowLambdaArn=${EXISTING_UPDATE_CONTACT_FLOW_LAMBDA_ARN:-}"
    "LexUILambdaName=${LEX_UI_LAMBDA_NAME:-Devops-Lex-UI}"
    "ExistingLexUILambdaArn=${EXISTING_LEX_UI_LAMBDA_ARN:-}"
    "LexPublishLambdaName=${LEX_PUBLISH_LAMBDA_NAME:-Devops-Lex-PublishLexZip-BKP}"
    "ExistingLexPublishLambdaArn=${EXISTING_LEX_PUBLISH_LAMBDA_ARN:-}"
    "ApiName=$API_NAME"
    "ApiStageName=$API_STAGE_NAME"
    "ExistingApiId=${EXISTING_API_ID:-}"
    "ExistingApiRootResourceId=${EXISTING_API_ROOT_RESOURCE_ID:-}"
    "ExistingLexResourceId=${EXISTING_LEX_RESOURCE_ID:-}"
    "PipelineName=$PIPELINE_NAME"
    "ExistingPipelineName=${EXISTING_PIPELINE_NAME:-}"
    "LexPipelineName=${LEX_PIPELINE_NAME:-Devops-Lex-Pipeline-BKP}"
    "ExistingLexPipelineName=${EXISTING_LEX_PIPELINE_NAME:-}"
    "LogRetentionDays=$LOG_RETENTION_DAYS"
    "ExistingUIGCLogGroupName=${EXISTING_UI_GC_LOG_GROUP_NAME:-}"
    "ExistingUpdateFlowLogGroupName=${EXISTING_UPDATE_FLOW_LOG_GROUP_NAME:-}"
    "ExistingLexUILogGroupName=${EXISTING_LEX_UI_LOG_GROUP_NAME:-}"
    "ExistingLexPublishLogGroupName=${EXISTING_LEX_PUBLISH_LOG_GROUP_NAME:-}"
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

success "CloudFormation deployment succeeded."
