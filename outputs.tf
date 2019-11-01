output "private_key" {
    value = "${module.keypair.private_key_pem}"
}

output "lb_hostname" {
    value = "${aws_lb.load_balancer.dns_name}"
}