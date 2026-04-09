variable "location" {
  type        = string
  description = "Azure region for all resources."
}

variable "name_prefix" {
  type        = string
  description = "Short lowercase prefix used to name resources (<= 8 chars, no dashes)."
}

variable "target_email_address" {
  type        = string
  description = "Mailbox the Logic App will monitor for incoming attachments."
}
