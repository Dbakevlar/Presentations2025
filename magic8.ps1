<# 
  magic8.ps1
  Cheeky Magic 8-Ball using local Ollama + Qwen.
  Usage: .\magic8.ps1  (you’ll be prompted for the question)
  Author:  Kellyn Gorman, Redgate
#>

# --- Defaults (auto-applied; no args needed) ---------------------------------
$OllamaHost = $env:OLLAMA_HOST
if ([string]::IsNullOrWhiteSpace($OllamaHost)) { $OllamaHost = 'http://localhost:11434' }

# Preferred then fallback model names
$PreferredModel = 'qwen2.5'
$FallbackModel  = 'qwen2.5-coder'

# --- Helpers -----------------------------------------------------------------
function Test-OllamaUp {
  try {
    $resp = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -Method Get -TimeoutSec 5
    return $true
  } catch {
    return $false
  }
}

function Get-OllamaModels {
  try {
    $resp = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -Method Get -TimeoutSec 10
    return @($resp.models.name)
  } catch {
    return @()
  }
}

function Ensure-Model([string]$model) {
  $have = Get-OllamaModels
  if ($have -contains $model) { return $model }

  # Try to pull if the ollama CLI is available
  $ollamaCmd = (Get-Command ollama -ErrorAction SilentlyContinue)
  if ($null -ne $ollamaCmd) {
    Write-Host "Pulling missing model '$model' via ollama CLI..." -ForegroundColor Yellow
    try {
      & $ollamaCmd.Source pull $model | Out-Null
      Start-Sleep -Seconds 1
      $have = Get-OllamaModels
      if ($have -contains $model) { return $model }
    } catch {
      # swallow and fall through to fallback
    }
  }

  # Use fallback if available, otherwise just return the original and hope for the best
  if ($have -contains $FallbackModel) { return $FallbackModel }
  return $model
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

$modelToUse = Ensure-Model $PreferredModel

# --- Prompt the user ---------------------------------------------------------
Write-Host ""
Write-Host " Ask the Magic 8-Ball your question:" -ForegroundColor Cyan
$question = Read-Host ">"

if ([string]::IsNullOrWhiteSpace($question)) {
  Write-Host "No question, no prophecy. Try again." -ForegroundColor DarkYellow
  exit 0
}

# --- Build the instruction ---------------------------------------------------
# We nudge the model to answer like a sassy/cheeky Magic 8-Ball in ONE short line.
# (We include classic 8-Ball vibes + snark, and ask for variability.)
$styleBlock = @"
You are a cheeky, sassy Magic 8-Ball. Answer in ONE short line, no preamble.
Channel the spirit of classic 8-Ball replies with playful sarcasm, e.g.:
- "As I see it, yes." with a wink
- "Outlook not so good." but snappier
- "Reply hazy, try again." but spicy
- "Don't count on it." with comedic flair

Rules:
- Be witty, a touch snarky, but not mean.
- Keep it to one sentence.
- No extra formatting, no quotes.
- Don’t repeat the question.
- Vary your phrasing; don’t just reuse stock lines.
Now respond to the user’s question.
"@

$fullPrompt = @"
$styleBlock

Question: $question
"@

# Temperature a bit higher to keep it lively; adjust if you want calmer outputs.
$options = @{
  temperature = 0.9
  top_p       = 0.9
  # You can experiment with presence_penalty/frequency_penalty in newer Ollama builds:
  # presence_penalty = 0.5
  # frequency_penalty = 0.2
}

# --- Ask the model -----------------------------------------------------------
try {
  $answer = Invoke-OllamaGenerate -model $modelToUse -prompt $fullPrompt -options $options
  # Clean and print a single snappy line
  $line = ($answer -split "`r?`n")[0].Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($line)) {
    $line = "Signs point to… my coffee machine is offline. Try again."
  }
  Write-Host ""
  Write-Host ("{0}" -f $line) -ForegroundColor Green
  Write-Host ""
} catch {
  Write-Host "The fates are busy: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Tip: ensure the Qwen model is available (e.g., 'ollama pull $PreferredModel' or '$FallbackModel')." -ForegroundColor DarkYellow
  exit 1
}
