<# 
  magic8.ps1
  Cheeky Magic 8-Ball using local Ollama + Qwen.
  Usage: .\magic8.ps1  (you’ll be prompted for the question)
  Author:  Kellyn Gorman, Redgate
#>

# --- Purpose -----------------------------------------------------------------
# Ensure Qwen 2.5 is present locally once, then run offline thereafter.
# - If the model isn't found locally, we temporarily disable offline mode to pull it.
# - If it is found, we stay fully offline (no re-downloads, no updates).

# --- Defaults (auto-applied; no args needed) ---------------------------------
$OllamaHost = $env:OLLAMA_HOST
if ([string]::IsNullOrWhiteSpace($OllamaHost)) { $OllamaHost = 'http://localhost:11434' }

# Force offline by default so we never auto-update unless a model is missing
$env:OLLAMA_OFFLINE = "1"

# Preferred then fallback model names
$PreferredModel = 'qwen2.5:7b'
$FallbackModel  = 'qwen2vl:7b'

# --- Helpers -----------------------------------------------------------------
function Test-OllamaUp {
  try {
    $null = Invoke-RestMethod -Uri "$OllamaHost/api/version" -Method Get -TimeoutSec 5
    return $true
  } catch {
    return $false
  }
}

function Get-OllamaModels {
  try {
    $resp = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -Method Get -TimeoutSec 10
    # Response shape: { "models": [ { "name": "qwen2.5", ... }, ... ] }
    return @($resp.models.name)
  } catch {
    return @()
  }
}

function Ensure-Model([string]$model, [string]$fallback) {
  $have = Get-OllamaModels
  if ($have -contains $model) {
#    Write-Host "Model '$model' found locally. Staying offline." -ForegroundColor DarkGreen
    return $model
  }

  # Try to pull ONLY IF missing (temporarily lift offline)
  $ollamaCmd = (Get-Command ollama -ErrorAction SilentlyContinue)
  if ($null -ne $ollamaCmd) {
    Write-Host "Model '$model' not found locally. Attempting one-time pull..." -ForegroundColor Yellow
    $prev = $env:OLLAMA_OFFLINE
    try {
      $env:OLLAMA_OFFLINE = $null  # allow network just for this pull
      & $ollamaCmd.Source pull $model
      Start-Sleep -Seconds 1
      $have = Get-OllamaModels
      if ($have -contains $model) {
        Write-Host "Pulled '$model' successfully. Returning to offline mode." -ForegroundColor DarkGreen
        return $model
      } else {
        Write-Host "Pull did not make '$model' available." -ForegroundColor DarkYellow
      }
    } catch {
      Write-Host "Pull failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    } finally {
      # Restore offline for the rest of the run
      $env:OLLAMA_OFFLINE = $prev
      if ([string]::IsNullOrWhiteSpace($env:OLLAMA_OFFLINE)) { $env:OLLAMA_OFFLINE = "1" }
    }
  } else {
    Write-Host "Ollama CLI not found on PATH; cannot pull '$model'." -ForegroundColor DarkYellow
  }

  # If still missing, try local fallback (no pulling)
  $have = Get-OllamaModels
  if ($have -contains $fallback) {
#    Write-Host "Using local fallback model '$fallback' (offline)." -ForegroundColor Yellow
    return $fallback
  }

  Write-Host "Neither '$model' nor '$fallback' is available locally." -ForegroundColor Red
  return $model  # server may have an alias; last resort
}

function Invoke-OllamaGenerate([string]$model, [string]$prompt, [hashtable]$options) {
  $payload = @{
    model   = $model
    prompt  = $prompt
    stream  = $false
    options = $options
  } | ConvertTo-Json -Depth 5

  $resp = Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 120
  return $resp.response
}

# --- Startup checks ----------------------------------------------------------
if (-not (Test-OllamaUp)) {
  Write-Host "Couldn’t reach Ollama at $OllamaHost." -ForegroundColor Red
  Write-Host "Make sure Ollama is running (e.g., start the Ollama app or run 'ollama serve')." -ForegroundColor DarkYellow
  exit 1
}

# Ensure Qwen 2.5 is present locally (pull once if needed), then run offline
$modelToUse = Ensure-Model -model $PreferredModel -fallback $FallbackModel

# --- Q&A Loop ---------------------------------------------------------------
while ($true) {
  # --- Prompt the user -------------------------------------------------------
  Write-Host ""
  Write-Host " Ask the Magic AI-Ball your question:" -ForegroundColor Cyan
  $question = Read-Host ">"

  if ([string]::IsNullOrWhiteSpace($question)) {
    Write-Host "No question, no prophecy. Try again." -ForegroundColor DarkYellow
    continue
  }

  # --- Build the instruction -------------------------------------------------
  $styleBlock = @"
You are a cheeky, sassy Magic 8-Ball. Answer in ONE short line, no preamble.
Channel the spirit of classic 8-Ball replies with playful sarcasm, but you're someone's boss e.g.:
- "As I see it, AI will fix it." with a wink
- "Outlook in the cloud not so good." but snappier
- "Reply hazy, No HA." but spicy
- "Don't count on a good backup." with comedic flair

Rules:
- Be witty, a touch snarky, but not mean.
- No extra formatting, no quotes.
- Don’t repeat the question.
- Vary your phrasing; throw in tech terms.
- Keep it to one sentence.
Now respond to the user’s question.
"@

  $fullPrompt = @"
$styleBlock

Question: $question
"@

  $options = @{
    temperature = 0.9
    top_p       = 0.9
    # presence_penalty = 0.5
    # frequency_penalty = 0.2
  }

  # --- Ask the model ---------------------------------------------------------
  try {
    $answer = Invoke-OllamaGenerate -model $modelToUse -prompt $fullPrompt -options $options
    $line = ($answer -split "`r?`n")[0].Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($line)) {
      $line = "Signs point to… my coffee machine is offline. Try again."
    }
    Write-Host ""
    Write-Host ("{0}" -f $line) -ForegroundColor Green
    Write-Host ""
  } catch {
    Write-Host "The fates are busy: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tip: ensure the Qwen model is available locally (e.g., run once with internet: 'ollama pull $PreferredModel')." -ForegroundColor DarkYellow
    continue
  }
}
