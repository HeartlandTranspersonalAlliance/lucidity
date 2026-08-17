output "summary" {
  description = "Non-secret identifiers for the enabled account security baseline."
  value = {
    audit_bucket            = aws_s3_bucket.audit.id
    cloudtrail_arn          = aws_cloudtrail.account.arn
    config_recorder_name    = aws_config_configuration_recorder.account.name
    guardduty_detector_id   = aws_guardduty_detector.account.id
    securityhub_account_arn = aws_securityhub_account_v2.account.arn
    security_kms_key_arn    = aws_kms_key.security.arn
  }
}
