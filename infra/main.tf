resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

locals {
  suffix       = random_string.suffix.result
  rg_name      = "rg-${var.name_prefix}-${local.suffix}"
  sa_name      = substr(replace("${var.name_prefix}sa${local.suffix}", "-", ""), 0, 24)
  kv_name      = "kv-${var.name_prefix}-${local.suffix}"
  func_name    = "func-${var.name_prefix}-${local.suffix}"
  plan_name    = "plan-${var.name_prefix}-${local.suffix}"
  logic_name   = "la-${var.name_prefix}-${local.suffix}"
  conn_name    = "outlook-${local.suffix}"
  ai_name      = "ai-${var.name_prefix}-${local.suffix}"
  container    = "attachments"

  tags = {
    project     = "file-upload"
    purpose     = "interview-homework"
    managed_by  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# Storage (function runtime + attachment blob container)
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "sa" {
  name                     = local.sa_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags
}

resource "azurerm_storage_container" "attachments" {
  name                  = local.container
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

# -----------------------------------------------------------------------------
# Application Insights
# -----------------------------------------------------------------------------
resource "azurerm_application_insights" "ai" {
  name                = local.ai_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  tags                = local.tags

  lifecycle {
    ignore_changes = [workspace_id]
  }
}

# -----------------------------------------------------------------------------
# Key Vault (stores function key for Logic App to call the upload endpoint)
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "kv" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  enable_rbac_authorization  = true
  tags                       = local.tags
}

resource "azurerm_role_assignment" "kv_admin_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# -----------------------------------------------------------------------------
# Function App (Linux Consumption, Python) — the "website"
# -----------------------------------------------------------------------------
resource "azurerm_service_plan" "plan" {
  name                = local.plan_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "func" {
  name                       = local.func_name
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.plan.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  https_only                 = true
  tags                       = local.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.ai.connection_string
    application_insights_key               = azurerm_application_insights.ai.instrumentation_key

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "python"
    BLOB_CONTAINER           = local.container
    STORAGE_ACCOUNT_NAME     = azurerm_storage_account.sa.name
    STORAGE_CONNECTION       = azurerm_storage_account.sa.primary_connection_string
  }
}

# Allow the Function App's managed identity to read/write blobs
resource "azurerm_role_assignment" "func_blob" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
}

# -----------------------------------------------------------------------------
# Outlook.com API Connection (must be authorized in the portal post-deploy)
# -----------------------------------------------------------------------------
resource "azapi_resource" "outlook" {
  type      = "Microsoft.Web/connections@2016-06-01"
  name      = local.conn_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location
  tags      = local.tags

  body = jsonencode({
    properties = {
      displayName = "Outlook.com (${var.target_email_address})"
      api = {
        id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Web/locations/${azurerm_resource_group.rg.location}/managedApis/outlook"
      }
    }
  })

  response_export_values = ["id", "name"]

  lifecycle {
    ignore_changes = [body]
  }
}

# -----------------------------------------------------------------------------
# Logic App: trigger on new email with attachments → POST each to Function
# -----------------------------------------------------------------------------
resource "azurerm_logic_app_workflow" "la" {
  name                = local.logic_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  workflow_parameters = {
    "$connections" = jsonencode({
      defaultValue = {}
      type         = "Object"
    })
  }

  parameters = {
    "$connections" = jsonencode({
      outlook = {
        connectionId   = azapi_resource.outlook.id
        connectionName = azapi_resource.outlook.name
        id             = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Web/locations/${azurerm_resource_group.rg.location}/managedApis/outlook"
      }
    })
  }
}

resource "azurerm_logic_app_trigger_custom" "on_email" {
  name         = "When_a_new_email_arrives"
  logic_app_id = azurerm_logic_app_workflow.la.id

  body = jsonencode({
    type = "ApiConnection"
    inputs = {
      host = {
        connection = { name = "@parameters('$connections')['outlook']['connectionId']" }
      }
      method = "get"
      path   = "/Mail/OnNewEmail"
      queries = {
        folderPath          = "Inbox"
        hasAttachments      = true
        includeAttachments  = true
        importance          = "Any"
      }
    }
    recurrence = {
      frequency = "Minute"
      interval  = 1
    }
    splitOn = "@triggerBody()?['value']"
  })
}

resource "azurerm_logic_app_action_custom" "for_each_attachment" {
  name         = "For_each_attachment"
  logic_app_id = azurerm_logic_app_workflow.la.id

  body = jsonencode({
    type    = "Foreach"
    foreach = "@triggerBody()?['Attachments']"
    actions = {
      Post_to_function = {
        type = "Http"
        inputs = {
          method = "POST"
          uri    = "https://${azurerm_linux_function_app.func.default_hostname}/upload"
          headers = {
            "x-filename"   = "@{items('For_each_attachment')?['Name']}"
            "x-from"       = "@{triggerBody()?['From']}"
            "x-subject"    = "@{triggerBody()?['Subject']}"
            "x-received"   = "@{triggerBody()?['DateTimeReceived']}"
            "Content-Type" = "application/octet-stream"
          }
          body = "@base64ToBinary(items('For_each_attachment')?['ContentBytes'])"
        }
      }
    }
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "function_app_url" {
  value       = "https://${azurerm_linux_function_app.func.default_hostname}"
  description = "Browse here to see uploaded files."
}

output "logic_app_name" {
  value = azurerm_logic_app_workflow.la.name
}

output "outlook_connection_name" {
  value       = azapi_resource.outlook.name
  description = "Authorize this connection in the Azure portal after deploy."
}

output "outlook_connection_id" {
  value       = azapi_resource.outlook.id
  description = "Full ARM ID of the Outlook API connection."
}

output "resource_group" {
  value = azurerm_resource_group.rg.name
}
