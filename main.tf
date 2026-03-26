provider "aws" {
  region = "eu-west-3"
}

# ==========================================
# 📦 1. LE COFFRE-FORT (Amazon ECR)
# ==========================================
resource "aws_ecr_repository" "app_repo" {
  name                 = "pmu-enterprise-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ==========================================
# 🔐 2. SÉCURITÉ ZERO TRUST (OIDC GitHub)
# ==========================================
# On dit à AWS : "Tu peux faire confiance aux serveurs de GitHub"
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"] # Empreintes officielles de GitHub
}

# ==========================================
# 🛂 3. LE BADGE D'ACCÈS (IAM Role pour GitHub)
# ==========================================
resource "aws_iam_role" "github_actions_role" {
  name = "GitHubActions-ECR-Push-Role"

  # La règle stricte : Seul GitHub peut assumer ce rôle, ET SEULEMENT pour TON dépôt !
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # 🚨 TRÈS IMPORTANT : Remplace par TON pseudo GitHub et le nom de ton repo !
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:AzzouzCherif/Oussama-pmu-backend:*"
          }
        }
      }
    ]
  })
}

# On donne à ce rôle UNIQUEMENT le droit de pousser des images sur ECR
resource "aws_iam_role_policy_attachment" "github_ecr_policy" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# ==========================================
# 🔗 4. OUTPUTS (Pour configurer GitHub plus tard)
# ==========================================
output "ecr_repository_url" {
  value = aws_ecr_repository.app_repo.repository_url
}

output "github_role_arn" {
  value = aws_iam_role.github_actions_role.arn
  description = "L'ARN du rôle à donner à GitHub Actions"
}

# ==========================================
# ⚡ 5. L'ORCHESTRATEUR (AWS Step Functions)
# ==========================================

resource "aws_sfn_state_machine" "deployment_orchestrator" {
  name     = "PMU-Deployment-Workflow"
  role_arn = aws_iam_role.step_functions_role.arn

definition = jsonencode({
    StartAt = "SecurityAudit",
    States = {
      # APPEL LAMBDA 1 : Sécurité
      "SecurityAudit": {
        "Type": "Task",
        "Resource": aws_lambda_function.security_check.arn,
        "Next": "IsRaceInProgress",
        "Retry": [{ "ErrorEquals": ["Lambda.ServiceException"], "IntervalSeconds": 2, "MaxAttempts": 3 }]
      },
      # APPEL LAMBDA 2 : Business Check
      "IsRaceInProgress": {
        "Type": "Task",
        "Resource": aws_lambda_function.race_check.arn,
        "Next": "DecisionStep"
      },
      # LOGIQUE DE DÉCISION
      "DecisionStep": {
        "Type": "Choice",
        "Choices": [
          { "Variable": "$.race_status", "StringEquals": "RACE_ON", "Next": "Wait1Minute" },
          { "Variable": "$.security_status", "StringEquals": "CRITICAL", "Next": "NotifyFailure" }
        ],
        "Default": "DeployToProduction"
      },
      # ATTENTE (Si course en cours)
      "Wait1Minute": {
        "Type": "Wait",
        "Seconds": 60,
        "Next": "IsRaceInProgress"
      },
      # DÉPLOIEMENT
      "DeployToProduction": {
        "Type": "Pass",
        "Result": { "status": "DEPLOYED" },
        "Next": "NotifySuccess"
      },
      # APPEL LAMBDA 3 : Succès
      "NotifySuccess": {
        "Type": "Task",
        "Resource": aws_lambda_function.notifier.arn,
        "End": true
      },
      "NotifyFailure": {
        "Type": "Task",
        "Resource": aws_lambda_function.notifier.arn,
        "End": true
      }
    }
  })
 }


# ==========================================
# 📡 6. LE DÉCLENCHEUR (Amazon EventBridge)
# ==========================================

# On crée la règle qui écoute l'ECR
resource "aws_cloudwatch_event_rule" "ecr_push_rule" {
  name        = "trigger-step-function-on-ecr-push"
  description = "Lance le déploiement quand une nouvelle image arrive dans ECR"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]
    detail = {
      action-type     = ["PUSH"]
      result          = ["SUCCESS"]
      repository-name = [aws_ecr_repository.app_repo.name]
    }
  })
}

# On lie la règle à notre Step Function
resource "aws_cloudwatch_event_target" "step_function_target" {
  rule      = aws_cloudwatch_event_rule.ecr_push_rule.name
  target_id = "SendToStepFunction"
  arn       = aws_sfn_state_machine.deployment_orchestrator.arn
  role_arn  = aws_iam_role.eventbridge_to_sfn_role.arn
}
# Rôle pour Step Functions
resource "aws_iam_role" "step_functions_role" {
  name = "StepFunctionsExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "states.amazonaws.com" } }]
  })
}

# Rôle pour qu'EventBridge puisse démarrer la Step Function
resource "aws_iam_role" "eventbridge_to_sfn_role" {
  name = "EventBridgeToSFNRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "events.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "sfn_trigger_policy" {
  role = aws_iam_role.eventbridge_to_sfn_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "states:StartExecution", Effect = "Allow", Resource = aws_sfn_state_machine.deployment_orchestrator.arn }]
  })
}

# ==========================================
# 🐍 LES MUSICIENS (AWS Lambda)
# ==========================================

# 1. Lambda de Sécurité
resource "aws_lambda_function" "security_check" {
  filename      = "lambda_security.zip"
  function_name = "pmu-security-auditor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
}

# 2. Lambda Business (Course en cours ?)
resource "aws_lambda_function" "race_check" {
  filename      = "lambda_race.zip"
  function_name = "pmu-race-validator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
}

# 3. Lambda de Notification
resource "aws_lambda_function" "notifier" {
  filename      = "lambda_notify.zip"
  function_name = "pmu-slack-notifier"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
}

resource "aws_iam_role_policy" "sfn_lambda_policy" {
  role = aws_iam_role.step_functions_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "lambda:InvokeFunction"
      Effect = "Allow"
      Resource = "*"
    }]
  })
}

# Rôle pour les Lambdas elles-mêmes
resource "aws_iam_role" "lambda_role" {
  name = "LambdaExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}