<?php
// Test-Fixture: unauffällige Datei
declare(strict_types=1);

function render(string $title): string
{
    return htmlspecialchars($title, ENT_QUOTES, 'UTF-8');
}

echo render('Hallo Welt');
