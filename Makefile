SHELL := /bin/bash

TF_DIR ?= terraform
PACKER_DIR ?= packer
TFVARS ?= ../examples/dev.tfvars
PACKER_VARS ?= backend.auto.pkrvars.hcl

.PHONY: init plan apply destroy fmt validate packer-init packer-build

init:
	cd $(TF_DIR) && terraform init

plan:
	cd $(TF_DIR) && terraform plan -var-file=$(TFVARS)

apply:
	cd $(TF_DIR) && terraform apply -var-file=$(TFVARS)

destroy:
	cd $(TF_DIR) && terraform destroy -var-file=$(TFVARS)

fmt:
	cd $(TF_DIR) && terraform fmt -recursive
	packer fmt $(PACKER_DIR)

validate:
	cd $(TF_DIR) && terraform validate
	packer validate -syntax-only $(PACKER_DIR)/backend-ami.pkr.hcl

packer-init:
	packer init $(PACKER_DIR)/backend-ami.pkr.hcl

packer-build:
	packer build -var-file=$(PACKER_DIR)/$(PACKER_VARS) $(PACKER_DIR)/backend-ami.pkr.hcl
