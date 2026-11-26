# No OCI ruleset exists for tflint; its bundled terraform ruleset still catches
# unused declarations, missing types and deprecated syntax.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
