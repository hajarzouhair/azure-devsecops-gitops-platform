#!/bin/bash

set -euo pipefail

# ------------------------------------------------------------
# Terraform Azure Remote Backend Bootstrap
#
# Creates the Azure Storage resources used to store
# Terraform remote state.
#
# This script does NOT migrate the Terraform state.
# The migration is performed later with:
#     terraform init -migrate-state
# ------------------------------------------------------------

RESOURCE_GROUP="rg-hajar-azure-project-tfstate"
LOCATION="francecentral"
STORAGE_ACCOUNT="sttfhajarazuredev"
CONTAINER_NAME="tfstate"

echo "==> Checking Azure authentication..."

az account show > /dev/null

echo "==> Creating backend Resource Group..."

az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

echo "==> Creating Terraform backend Storage Account..."

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2 \
  --output none

echo "==> Creating Terraform state container..."

az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --output none

echo
echo "=========================================="
echo "Terraform backend successfully created"
echo "=========================================="
echo "Resource Group : $RESOURCE_GROUP"
echo "Location       : $LOCATION"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container      : $CONTAINER_NAME"
echo
echo "Next step:"
echo "Configure the azurerm backend in Terraform"
echo "and migrate the existing local state."
