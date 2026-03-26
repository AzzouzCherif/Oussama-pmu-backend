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
    Comment = "Orchestrateur de déploiement intelligent avec validation et rollback"
    StartAt = "NotifyDeploymentStart"
    States = {
      # Étape 1 : Notification de début
      "NotifyDeploymentStart": {
        "Type": "Pass",
        "Result": "Déploiement initié sur Fargate...",
        "Next": "DeployToECS"
      },
      # Étape 2 : Déploiement (Simulation)
      "DeployToECS": {
        "Type": "Wait",
        "Seconds": 5,
        "Next": "HealthCheck"
      },
      # Étape 3 : Le Health Check (Le moment critique)
      "HealthCheck": {
        "Type": "Choice",
        "Choices": [
          {
            "Variable": "$.status",
            "StringEquals": "FAILED",
            "Next": "Rollback"
          }
        ],
        "Default": "SuccessNotification"
      },
      # Étape 4A : Succès
      "SuccessNotification": {
        "Type": "Pass",
        "Result": "Déploiement réussi ! Le site est en ligne.",
        "End": true
      },
      # Étape 4B : Échec & Rollback
      "Rollback": {
        "Type": "Pass",
        "Result": "Alerte ! Erreur détectée. Retour à la version précédente...",
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