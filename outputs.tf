output "ips" {
  value = merge(
    { for name in local.names: name => aws_instance.k3s[name].public_ip },
    { "db" = aws_instance.db.public_ip }
  )
}
