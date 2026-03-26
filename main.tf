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