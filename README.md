# IVR Migration - Third-Party Deployment Package

This package contains the CloudFormation templates, Lambda source, and deployment script for the IVR Migration application.

## Before deployment

1. Configure AWS credentials for the target AWS account.
   - `AWS_PROFILE` in `deploy.config` is optional. Leave it empty to use the active AWS credentials/role, or set a named AWS CLI profile.
2. Set `AWS_REGION` in `deploy.config` to the target AWS region.
3. Set `CODECOMMIT_REPOSITORY_NAME` and `CODECOMMIT_BRANCH_NAME` to the repository/branch used by the target environment.
4. Review the application/resource names in `deploy.config` and change them if the target account already uses those names for unrelated resources.
5. Leave the `EXISTING_*` values empty for normal first deployment. `deploy.sh` will discover matching existing resources by the configured names and reuse them where supported.
6. If a specific existing resource must be reused, provide its corresponding `EXISTING_*` value explicitly.
7. Keep `DEPLOY_FRONTEND=false` unless the frontend source is available in the package and the target deployment is intended to create the frontend infrastructure.

## Deployment

```bash
chmod +x deploy.sh
bash -n deploy.sh
./deploy.sh
```

The script:

- validates the AWS identity and target region;
- creates or reuses the deployment bucket;
- discovers matching existing resources only on a first deployment;
- shows a pre-deployment create/reuse plan;
- packages and uploads the Lambda source;
- uploads nested CloudFormation templates;
- validates and deploys `root.yaml`;
- updates reused Lambda functions in place while preserving their existing ARNs;
- prints CloudFormation outputs.

## Existing-resource safety

For resources with `EXISTING_*` parameters, an existing resource is referenced rather than recreated. Persistent resources created by the templates use `Retain`/`UpdateReplacePolicy: Retain` where applicable.

Once the root stack exists, `deploy.sh` restores existing-resource ownership from the stack parameters instead of rediscovering resources. This prevents a later deployment from accidentally changing a CloudFormation-managed resource into an externally reused resource.

## Important scope note

The package provisions the AWS infrastructure and migration application components. Individual Amazon Connect contact-flow promotion failures can still depend on the contents and resource dependencies of the contact-flow JSON being migrated (for example queues, operating hours, or referenced contact flows). Such flow-level validation failures are separate from CloudFormation infrastructure deployment.
