variable "project_id" {
  description = "Existing environment project; narration never creates another project."
  type        = string
}
variable "region" {
  description = "Existing worker region, also used for private narration tasks."
  type        = string
}
