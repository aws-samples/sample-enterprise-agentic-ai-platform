data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# KMS — customer managed key for pipeline artifacts and CodeBuild output.
# The key policy grants the CodeBuild and CodePipeline roles directly, so it
# works for both platform-created and bring-your-own role ARNs.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "artifacts_key" {
  #checkov:skip=CKV_AWS_111:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_356:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_109:Account-root kms:* is the AWS default key-policy statement that lets IAM policies govern the key.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "PipelineRolesUseKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = distinct([local.codebuild_role_arn, local.codepipeline_role_arn])
    }
  }
}

resource "aws_kms_key" "artifacts" {
  description             = "Pipeline artifacts and CodeBuild output for ${local.prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.artifacts_key.json
  tags                    = var.tags
}
