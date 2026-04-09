# =============================================================================
# deploy.ps1 — Interactive Terraform runner for the file-upload project
# =============================================================================

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# 1. ReadMe / usage banner
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Email-to-Website File Upload — Terraform Runner" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will:" -ForegroundColor White
Write-Host "  1. Load project inputs from .\inputs.ps1" -ForegroundColor Gray
Write-Host "  2. Sign in to Azure (skipped if already on the right subscription)" -ForegroundColor Gray
Write-Host "  3. Show an interactive menu to run Terraform commands against .\infra" -ForegroundColor Gray
Write-Host ""
Write-Host "Prerequisites:" -ForegroundColor White
Write-Host "  - Terraform >= 1.5 on PATH" -ForegroundColor Gray
Write-Host "  - Azure CLI installed" -ForegroundColor Gray
Write-Host "  - inputs.ps1 filled in with tenant, subscription, prefix, email" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# 2. Load inputs
# -----------------------------------------------------------------------------
$repoRoot   = $PSScriptRoot
$inputsFile = Join-Path $repoRoot "inputs.ps1"
$infraDir   = Join-Path $repoRoot "infra"

if (-not (Test-Path $inputsFile)) { throw "inputs.ps1 not found at $inputsFile" }
if (-not (Test-Path $infraDir))   { throw "infra directory not found at $infraDir" }

Write-Host "Loading inputs from $inputsFile ..." -ForegroundColor Cyan
. $inputsFile

$missing = @()
if (-not $env:ARM_TENANT_ID)               { $missing += "Azure_Tenant_Id" }
if (-not $env:ARM_SUBSCRIPTION_ID)         { $missing += "Azure_Subscription_Id" }
if (-not $env:TF_VAR_location)             { $missing += "Azure_Location" }
if (-not $env:TF_VAR_name_prefix)          { $missing += "Name_Prefix" }
if (-not $env:TF_VAR_target_email_address) { $missing += "Target_Email_Address" }
if ($missing.Count -gt 0) { throw "inputs.ps1 is missing values for: $($missing -join ', ')" }

Write-Host "  Tenant       : $env:ARM_TENANT_ID"               -ForegroundColor Gray
Write-Host "  Subscription : $env:ARM_SUBSCRIPTION_ID"         -ForegroundColor Gray
Write-Host "  Location     : $env:TF_VAR_location"             -ForegroundColor Gray
Write-Host "  Name prefix  : $env:TF_VAR_name_prefix"          -ForegroundColor Gray
Write-Host "  Target email : $env:TF_VAR_target_email_address" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# 3. Azure login
# -----------------------------------------------------------------------------
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " az login" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

$currentAccount = az account show --output json 2>$null | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $env:ARM_SUBSCRIPTION_ID) {
    Write-Host "Signing in to tenant $env:ARM_TENANT_ID ..." -ForegroundColor Yellow
    az login --tenant $env:ARM_TENANT_ID --output none
    if ($LASTEXITCODE -ne 0) { throw "az login failed (exit $LASTEXITCODE)" }

    az account set --subscription $env:ARM_SUBSCRIPTION_ID
    if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE)" }
} else {
    Write-Host "Already signed in as $($currentAccount.user.name) on subscription $($currentAccount.name)." -ForegroundColor Green
}

$active = az account show --output json | ConvertFrom-Json
Write-Host "  Account      : $($active.user.name)" -ForegroundColor Gray
Write-Host "  Subscription : $($active.name) ($($active.id))" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# 4. Terraform action functions
# -----------------------------------------------------------------------------
function Invoke-TfInit {
    Write-Host ""
    Write-Host "--- terraform init ---" -ForegroundColor Cyan
    terraform -chdir="$infraDir" init -input=false
    if ($LASTEXITCODE -ne 0) { Write-Host "terraform init failed (exit $LASTEXITCODE)" -ForegroundColor Red }
}

function Invoke-TfPlan {
    Write-Host ""
    Write-Host "--- terraform plan ---" -ForegroundColor Cyan
    terraform -chdir="$infraDir" plan -input=false -out="tfplan.binary"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "terraform plan failed (exit $LASTEXITCODE)" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "--- Plan Summary ---" -ForegroundColor Cyan
    $planJson = terraform -chdir="$infraDir" show -json tfplan.binary | ConvertFrom-Json

    $create = @(); $update = @(); $destroy = @()
    foreach ($rc in $planJson.resource_changes) {
        $actions = $rc.change.actions
        if     ($actions -contains "create" -and $actions -contains "delete") { $destroy += $rc.address; $create += $rc.address }
        elseif ($actions -contains "create") { $create  += $rc.address }
        elseif ($actions -contains "update") { $update  += $rc.address }
        elseif ($actions -contains "delete") { $destroy += $rc.address }
    }

    Write-Host ("  To create  : {0}" -f $create.Count)  -ForegroundColor Green
    Write-Host ("  To update  : {0}" -f $update.Count)  -ForegroundColor Yellow
    Write-Host ("  To destroy : {0}" -f $destroy.Count) -ForegroundColor Red

    if ($create.Count)  { Write-Host ""; $create  | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green } }
    if ($update.Count)  { Write-Host ""; $update  | ForEach-Object { Write-Host "  ~ $_" -ForegroundColor Yellow } }
    if ($destroy.Count) { Write-Host ""; $destroy | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red } }

    Write-Host ""
    Write-Host "Plan saved to: $infraDir\tfplan.binary" -ForegroundColor Cyan
}

function Invoke-TfApply {
    Write-Host ""
    Write-Host "--- terraform apply ---" -ForegroundColor Cyan
    $planFile = Join-Path $infraDir "tfplan.binary"
    if (Test-Path $planFile) {
        Write-Host "Applying saved plan tfplan.binary ..." -ForegroundColor Yellow
        terraform -chdir="$infraDir" apply "tfplan.binary"
    } else {
        Write-Host "No saved plan found — running interactive apply." -ForegroundColor Yellow
        terraform -chdir="$infraDir" apply
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "terraform apply failed (exit $LASTEXITCODE)" -ForegroundColor Red }
}

function Invoke-PrereqCheck {
    Write-Host ""
    Write-Host "--- Prerequisite Check ---" -ForegroundColor Cyan
    $tools = @(
        @{ Name = "terraform"; Cmd = "terraform"; Args = @("version");      Hint = "https://developer.hashicorp.com/terraform/install" },
        @{ Name = "Azure CLI"; Cmd = "az";        Args = @("--version");      Hint = "winget install Microsoft.AzureCLI" },
        @{ Name = "Functions Core Tools"; Cmd = "func"; Args = @("--version"); Hint = "winget install Microsoft.Azure.FunctionsCoreTools" },
        @{ Name = "Python";    Cmd = "python";   Args = @("--version");    Hint = "winget install Python.Python.3.11" }
    )

    $allOk = $true
    foreach ($t in $tools) {
        $found = Get-Command $t.Cmd -ErrorAction SilentlyContinue
        if ($found) {
            $verOutput = & $t.Cmd $t.Args 2>&1 | Select-Object -First 1
            Write-Host ("  [OK]    {0,-22} {1}" -f $t.Name, $verOutput) -ForegroundColor Green
        } else {
            Write-Host ("  [MISS]  {0,-22} install: {1}" -f $t.Name, $t.Hint) -ForegroundColor Red
            $allOk = $false
        }
    }

    if (Test-Path $inputsFile) {
        Write-Host ("  [OK]    {0,-22} {1}" -f "inputs.ps1", $inputsFile) -ForegroundColor Green
    } else {
        Write-Host ("  [MISS]  {0,-22} {1}" -f "inputs.ps1", $inputsFile) -ForegroundColor Red
        $allOk = $false
    }

    Write-Host ""
    if ($allOk) {
        Write-Host "All prerequisites satisfied." -ForegroundColor Green
    } else {
        Write-Host "One or more prerequisites are missing — install them and re-run this check." -ForegroundColor Yellow
    }
}

function Invoke-AuthorizeOutlook {
    Write-Host ""
    Write-Host "--- Authorize Outlook API Connection ---" -ForegroundColor Cyan

    $connId = terraform -chdir="$infraDir" output -raw outlook_connection_id 2>$null
    if (-not $connId) {
        # Fallback: discover via az
        $rg = terraform -chdir="$infraDir" output -raw resource_group 2>$null
        if (-not $rg) {
            Write-Host "Could not determine resource group from Terraform outputs. Run apply first." -ForegroundColor Red
            return
        }
        $connName = az resource list --resource-group $rg --resource-type "Microsoft.Web/connections" --query "[0].name" -o tsv
        if (-not $connName) {
            Write-Host "No API connection found in $rg." -ForegroundColor Red
            return
        }
        $connId = az resource show --resource-group $rg --name $connName --resource-type "Microsoft.Web/connections" --query id -o tsv
    }

    $url = "https://portal.azure.com/#@$($env:ARM_TENANT_ID)/resource$($connId)/edit"
    Write-Host "Opening browser to:" -ForegroundColor Yellow
    Write-Host "  $url" -ForegroundColor Gray
    Write-Host ""
    Write-Host "In the portal: click 'Authorize' > sign in as the target mailbox > Save." -ForegroundColor White
    Start-Process $url
}

function Invoke-PublishFunction {
    Write-Host ""
    Write-Host "--- Publish Function App code ---" -ForegroundColor Cyan

    if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
        Write-Host "Azure Functions Core Tools ('func') not found on PATH." -ForegroundColor Red
        Write-Host "Install with: winget install Microsoft.Azure.FunctionsCoreTools" -ForegroundColor Yellow
        return
    }

    $funcUrl = terraform -chdir="$infraDir" output -raw function_app_url 2>$null
    if (-not $funcUrl) {
        Write-Host "Could not read function_app_url from Terraform outputs. Run apply first." -ForegroundColor Red
        return
    }
    $funcName = ($funcUrl -replace "^https?://", "") -split "\." | Select-Object -First 1

    $functionDir = Join-Path $repoRoot "function"
    if (-not (Test-Path (Join-Path $functionDir "host.json"))) {
        Write-Host "host.json not found at $functionDir." -ForegroundColor Red
        return
    }

    Write-Host "Publishing $functionDir -> $funcName ..." -ForegroundColor Yellow
    Push-Location $functionDir
    try {
        func azure functionapp publish $funcName --python --build remote
    } finally {
        Pop-Location
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "func publish failed (exit $LASTEXITCODE)" -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "Published. Browse to: $funcUrl" -ForegroundColor Green
    }
}

function Invoke-TfDestroy {
    Write-Host ""
    Write-Host "--- terraform destroy ---" -ForegroundColor Red
    Write-Host "This will DESTROY all resources managed by Terraform in .\infra." -ForegroundColor Red
    $confirm = Read-Host "Type 'destroy' to confirm"
    if ($confirm -ne "destroy") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
    terraform -chdir="$infraDir" destroy
    if ($LASTEXITCODE -ne 0) { Write-Host "terraform destroy failed (exit $LASTEXITCODE)" -ForegroundColor Red }
}

# -----------------------------------------------------------------------------
# 5. Interactive menu loop
# -----------------------------------------------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Choose an action" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  1) check prerequisites"
    Write-Host "  2) terraform init"
    Write-Host "  3) terraform plan"
    Write-Host "  4) terraform apply"
    Write-Host "  5) authorize Outlook API connection (opens browser)"
    Write-Host "  6) publish Function App Python code"
    Write-Host "  7) terraform destroy" -ForegroundColor Red
    Write-Host "  Q) quit"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Selection"
    switch ($choice.Trim().ToLower()) {
        "1" { Invoke-PrereqCheck }
        "2" { Invoke-TfInit }
        "3" { Invoke-TfPlan }
        "4" { Invoke-TfApply }
        "5" { Invoke-AuthorizeOutlook }
        "6" { Invoke-PublishFunction }
        "7" { Invoke-TfDestroy }
        "q" { Write-Host "Goodbye."; break }
        default { Write-Host "Invalid selection: '$choice'" -ForegroundColor Yellow }
    }
    if ($choice.Trim().ToLower() -eq "q") { break }
}
