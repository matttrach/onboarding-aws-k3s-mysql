output "ips" {
  value = { for name in local.names: name => aws_instance.k3s[name].public_ip }
}
