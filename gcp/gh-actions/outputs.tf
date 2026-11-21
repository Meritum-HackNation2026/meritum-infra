output "runners" {
  description = "Runner VMs with their public IPs."
  value       = { for name, vm in google_compute_instance.gh_runner : name => vm.network_interface[0].access_config[0].nat_ip }
}

output "ssh_hint" {
  value = "ssh -i .ssh/meritum-runner ${var.admin_user}@<ip>"
}
