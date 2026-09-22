param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$destination = Join-Path $Root '.build/smoke-source'
[void][System.IO.Directory]::CreateDirectory($destination)
Copy-Item -LiteralPath (Join-Path $Root 'build/СозданиеУКД.xml') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $Root 'build/СозданиеУКД') -Destination $destination -Recurse -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)
$formPath = Join-Path $destination 'СозданиеУКД/Forms/Форма/Ext/Form.xml'
[xml]$form = [System.IO.File]::ReadAllText($formPath)
$events = $form.SelectSingleNode('/*/*[local-name()="Events"]')
$event = $events.SelectSingleNode('*[local-name()="Event" and @name="OnOpen"]')
if ($null -eq $event) {
    $event = $form.CreateElement('Event', $form.DocumentElement.NamespaceURI)
    $event.SetAttribute('name', 'OnOpen')
    [void]$events.AppendChild($event)
}
$event.InnerText = 'ТестПриОткрытии'
$form.Save($formPath)
$runIdPath = Join-Path $Root '.build/smoke-run-id.txt'
if (-not (Test-Path -LiteralPath $runIdPath)) {
    [System.IO.File]::WriteAllText($runIdPath, [guid]::NewGuid().ToString(), $utf8)
}
$runId = [System.IO.File]::ReadAllText($runIdPath).Trim()
$report = Join-Path $Root '.build/smoke-result.txt'
$testModule = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Smoke-Module.bsl'))
$testModule = $testModule.Replace('@@RUN_ID@@', $runId).Replace('@@REPORT@@', $report.Replace('"', '""'))
$modulePath = Join-Path $destination 'СозданиеУКД/Forms/Форма/Ext/Form/Module.bsl'
[System.IO.File]::AppendAllText($modulePath, [Environment]::NewLine + $testModule, $utf8)
$objectPath = Join-Path $destination 'СозданиеУКД/Ext/ObjectModule.bsl'
$objectModule = [System.IO.File]::ReadAllText($objectPath)
$needle = 'СчетФактура = СоздатьСчетФактуру(Корректировка.Ссылка, ДатаДокументов, Маркер);'
$injection = 'Если Параметры.НомерЦепочки = 11 Тогда ВызватьИсключение "UKD_TEST_ROLLBACK"; КонецЕсли;'
if (-not $objectModule.Contains($needle)) { throw 'Rollback injection point not found' }
$objectModule = $objectModule.Replace($needle, $injection + [Environment]::NewLine + $needle)
[System.IO.File]::WriteAllText($objectPath, $objectModule, $utf8)
Write-Output "Prepared smoke EPF sources. Run ID: $runId"
Write-Output 'The smoke run commits 10 chains (40 documents); chain 11 must roll back.'
