# Config
AWS_PROFILE ?= default
AWS_REGION  ?= eu-west-1
ACCOUNT     := $(shell aws sts get-caller-identity --query Account --output text --region $(AWS_REGION) --profile $(AWS_PROFILE))
BUCKET      ?= techtest-cfn-templates-$(ACCOUNT)-$(AWS_REGION)
PREFIX      ?= cloudformation/

# ECS image/port test defaults (can be overwritten in CLI)
CONTAINER_IMAGE ?= nginxdemos/hello:latest
CONTAINER_PORT  ?= 80
HEALTH_PATH     ?= /
DESIRED_COUNT   ?= 1
TASK_CPU        ?= 256
TASK_MEM        ?= 512

# S3: create + secure + sync
.PHONY: s3-create s3-secure s3-sync s3-all
s3-create:
ifeq ($(AWS_REGION),us-east-1)
	aws s3api create-bucket --bucket "$(BUCKET)" --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"
else
	aws s3api create-bucket --bucket "$(BUCKET)" --region "$(AWS_REGION)" \
	  --create-bucket-configuration LocationConstraint="$(AWS_REGION)" --profile "$(AWS_PROFILE)"
endif

s3-secure:
	# Disable public access
	aws s3api put-public-access-block --bucket "$(BUCKET)" \
	  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"
	# Basic encryprion (SSE-S3)
	aws s3api put-bucket-encryption --bucket "$(BUCKET)" \
	  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"
	# Versioning (optional)
	# aws s3api put-bucket-versioning --bucket "$(BUCKET)" --versioning-configuration Status=Enabled \
	#   --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"

s3-sync:
	aws s3 sync cloudformation/ s3://$(BUCKET)/$(PREFIX) --delete --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"

s3-all: s3-create s3-secure s3-sync

# Nested deploy / update
.PHONY: deploy-main outputs-main
deploy-main:
	aws cloudformation deploy \
	  --stack-name main-stack \
	  --template-file cloudformation/main.yml \
	  --parameter-overrides \
	    TemplatesBucket=$(BUCKET) \
	    TemplatesPrefix=$(PREFIX) \
	    EnvironmentName=techtest \
	    ContainerImage=$(CONTAINER_IMAGE) \
	    ContainerPort=$(CONTAINER_PORT) \
	    HealthCheckPath=$(HEALTH_PATH) \
	    DesiredCount=$(DESIRED_COUNT) \
	    TaskCpu=$(TASK_CPU) \
	    TaskMemory=$(TASK_MEM) \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"

outputs-main:
	@echo "== EC2 outputs =="
	aws cloudformation describe-stacks --stack-name ec2-web-stack \
	  --query "Stacks[0].Outputs" --output table \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true
	@echo "== Lambda API URL =="
	aws cloudformation describe-stacks --stack-name lambda-stack \
	  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true
	@echo "== ECS ALB DNS =="
	aws cloudformation describe-stacks --stack-name ecs-stack \
	  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" --output text \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true

# One-shot: S3 create+secure+sync then nested deploy
.PHONY: deploy-all
deploy-all: s3-all deploy-main outputs-main

# Convenience: switch image quickly (no S3 resync needed)
.PHONY: set-image-hello set-image-node
set-image-hello:
	$(MAKE) deploy-main CONTAINER_IMAGE=nginxdemos/hello:latest CONTAINER_PORT=80 HEALTH_PATH=/

# Example: own node.js image (8080):
set-image-node:
	$(MAKE) deploy-main CONTAINER_IMAGE=mcudivide/sample-nodejs-app:latest CONTAINER_PORT=8080 HEALTH_PATH=/

# Destroy + bucket cleanup
.PHONY: destroy-main s3-empty s3-delete nuke
destroy-main:
	-aws cloudformation delete-stack --stack-name main-stack --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"
	-aws cloudformation wait stack-delete-complete --stack-name main-stack --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)"

s3-empty:
	-aws s3 rm s3://$(BUCKET)/ --recursive --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true

s3-delete:
	-aws s3api delete-bucket --bucket "$(BUCKET)" --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true

s3-delete-all:
	-aws s3api list-object-versions --bucket "$BUCKET" --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.Versions[]?, .DeleteMarkers[]? | [.Key, .VersionId] | @tsv' | while IFS=$'\t' read -r key ver; do aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" --region "$AWS_REGION" --profile "$AWS_PROFILE"; done

nuke: destroy-main s3-empty s3-delete s3-delete-all
	@echo "All gone."

# Optional: ECR flow
ECR_REPO ?= techtest-app

.PHONY: ecr-create ecr-login ecr-build-push ecr-deploy
ecr-create:
	aws ecr create-repository --repository-name $(ECR_REPO) \
	  --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" || true

ecr-login:
	aws ecr get-login-password --region "$(AWS_REGION)" --profile "$(AWS_PROFILE)" | \
	docker login --username AWS --password-stdin $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com

ecr-build-push:
	docker build -t $(ECR_REPO):latest ./ecs-app
	docker tag $(ECR_REPO):latest $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO):latest
	docker push $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO):latest

ecr-deploy:
	$(MAKE) deploy-main CONTAINER_IMAGE=$$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO):latest

