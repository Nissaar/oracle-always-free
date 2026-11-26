# Email when the guard rails or the CI permissions change.
#
# The spending-cap quotas, the IAM policies, the users and the CI trust can only
# be changed from your laptop (this stack), but nothing told you when they were.
# An OCI Events rule watches the tenancy and sends one email per matching event
# through a Notifications topic. Events and Notifications are free at this size
# (Notifications: first 1,000 emails a month free).
#
# The rule and topic sit in the tenancy (root) compartment: policies and users
# belong to the tenancy, and a rule only sees events of its own compartment and
# the ones below it.
#
# What is NOT covered, because the Events reference does not list it (checked
# 2026-11-25 against docs.oracle.com, "Services that Produce Events"):
#   - quota policies (Limits service): no event types listed;
#   - Identity Domains objects (users made with oci_identity_domains_user, the
#     identity propagation trust, the OAuth app): no event types listed. The
#     legacy IAM events below may or may not fire for them; test once (README
#     "Change alerts").
# Nothing is guessed here: add a type only after seeing it in a real event.

locals {
  audit_email = var.audit_email != "" ? var.audit_email : var.alert_email

  # Exact strings from Oracle's Events reference, IAM section. The reference
  # writes the service part both as identityControlPlane (tables) and
  # identitycontrolplane (examples), and other docs show the action in lower
  # case, so every spelling is listed: a wrong spelling matches nothing, an
  # extra one costs nothing.
  audit_actions = [
    "CreatePolicy", "UpdatePolicy", "DeletePolicy",
    "CreateUser", "UpdateUser", "DeleteUser", "UpdateUserCapabilities", "UpdateUserState",
    "CreateIdentityProvider", "UpdateIdentityProvider", "DeleteIdentityProvider",
  ]
  audit_event_types = distinct(flatten([
    for service in ["identityControlPlane", "identitycontrolplane"] : [
      for action in local.audit_actions : [
        "com.oraclecloud.${service}.${action}",
        "com.oraclecloud.${service}.${lower(action)}",
      ]
    ]
  ]))
}

resource "oci_ons_notification_topic" "audit" {
  compartment_id = var.tenancy_ocid
  name           = "audit-changes"
  description    = "Changes to policies, users and identity providers (OCI Events rule audit-changes)."
}

# The recipient gets a confirmation email and must click it: until then
# the subscription stays PENDING and no alert is delivered.
resource "oci_ons_subscription" "audit_email" {
  compartment_id = var.tenancy_ocid
  topic_id       = oci_ons_notification_topic.audit.id
  protocol       = "EMAIL"
  endpoint       = local.audit_email
}

resource "oci_events_rule" "audit" {
  compartment_id = var.tenancy_ocid
  display_name   = "audit-changes"
  description    = "Email on policy, user and identity provider changes."
  is_enabled     = true
  condition      = jsonencode({ eventType = local.audit_event_types })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = oci_ons_notification_topic.audit.id
      description = "Send to the audit-changes topic"
    }
  }
}
