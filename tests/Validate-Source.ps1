param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$configuration = Join-Path $Root 'УТ 11.6'
$processor = Join-Path $Root 'build/СозданиеУКД'
$issues = [System.Collections.Generic.List[string]]::new()
$bsl = (Get-ChildItem $processor -Filter '*.bsl' -Recurse | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
}) -join "`n"

function Read-Metadata([string]$category, [string]$name) {
    [xml](Get-Content -LiteralPath (Join-Path $configuration "$category/$name.xml") -Raw -Encoding UTF8)
}

# References to enumerations are checked against the supplied configuration.
foreach ($match in [regex]::Matches($bsl, 'Перечисления\.([А-Яа-яЁё\w]+)\.([А-Яа-яЁё\w]+)')) {
    $name = $match.Groups[1].Value
    $value = $match.Groups[2].Value
    if ($value -eq 'ПустаяСсылка') { continue }
    $xml = Read-Metadata 'Enums' $name
    $values = @($xml.SelectNodes('//*[local-name()="EnumValue"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
    if ($value -notin $values) { $issues.Add("Unknown enumeration value: $name.$value") }
}

# Check external calls against exported methods, including platform XML scope.
foreach ($match in [regex]::Matches($bsl, '(?<![.А-Яа-яЁё\w])([А-Яа-яЁё]\w+)\.([А-Яа-яЁё]\w+)\(')) {
    $moduleName = $match.Groups[1].Value
    $methodName = $match.Groups[2].Value
    $path = Join-Path $configuration "CommonModules/$moduleName/Ext/Module.bsl"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $module = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $pattern = '(?ms)^(?:Процедура|Функция)\s+' + [regex]::Escape($methodName) + '\s*\([^)]*\)\s*Экспорт'
    if ($module -notmatch $pattern) { $issues.Add("Missing exported method: $moduleName.$methodName") }
}

# Check properties used on explicitly known metadata objects.
$objects = @{
    'СоглашениеОбъект' = @('Catalogs', 'СоглашенияСКлиентами')
    'СкладОбъект' = @('Catalogs', 'Склады')
    'ТоварОбъект' = @('Catalogs', 'Номенклатура')
    'Вид' = @('Catalogs', 'ВидыНоменклатуры')
    'ОбъектПодразделения' = @('Catalogs', 'СтруктураПредприятия')
    'ПартнерОбъект' = @('Catalogs', 'Партнеры')
}
foreach ($variable in $objects.Keys) {
    $metadata = Read-Metadata $objects[$variable][0] $objects[$variable][1]
    $properties = @('Наименование', 'Код', 'Ссылка', 'НаименованиеПолное', 'ЭтоГруппа')
    $properties += @($metadata.SelectNodes('//*[local-name()="Attribute" or local-name()="TabularSection"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
    foreach ($match in [regex]::Matches($bsl, '(?<![А-Яа-яЁё\w])' + $variable + '\.([А-Яа-яЁё]\w+)\s*(?:=|\.)')) {
        $property = $match.Groups[1].Value
        if ($property -notin $properties) { $issues.Add("Unknown property: $variable.$property") }
    }
}

[xml]$processorMetadata = Get-Content -LiteralPath (Join-Path $Root 'build/СозданиеУКД.xml') -Raw -Encoding UTF8
[xml]$form = Get-Content -LiteralPath (Join-Path $processor 'Forms/Форма/Ext/Form.xml') -Raw -Encoding UTF8
[xml]$instructionForm = Get-Content -LiteralPath (Join-Path $processor 'Forms/Инструкция/Ext/Form.xml') -Raw -Encoding UTF8
# Verify each document factory against its own header and goods metadata.
$factories = @{
    'ЗаполнитьРеализацию' = 'РеализацияТоваровУслуг'
    'ЗаполнитьКорректировку' = 'КорректировкаРеализации'
    'СоздатьСчетФактуру' = 'СчетФактураВыданный'
}
foreach ($factory in $factories.Keys) {
    $metadata = Read-Metadata 'Documents' $factories[$factory]
    $documentProperties = @('Дата', 'Комментарий', 'Ссылка', 'Номер', 'Проведен', 'ПометкаУдаления')
    $documentProperties += @($metadata.SelectNodes('/*/*/*[local-name()="ChildObjects"]/*[local-name()="Attribute" or local-name()="TabularSection"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
    $fragment = [regex]::Match($bsl, '(?ms)^Функция ' + $factory + '\(.*?^КонецФункции').Value
    foreach ($match in [regex]::Matches($fragment, '\bДокумент\.([А-Яа-яЁё]\w+)\s*(?:=|\.|\[)')) {
        if ($match.Groups[1].Value -notin $documentProperties) {
            $issues.Add("Unknown document property: $factory.$($match.Groups[1].Value)")
        }
    }
    if ($factory -eq 'СоздатьСчетФактуру') { continue }
    if ($factory -eq 'ЗаполнитьКорректировку') {
        $discrepancies = $metadata.SelectSingleNode('//*[local-name()="TabularSection"][*[local-name()="Properties"]/*[local-name()="Name"]="Расхождения"]')
        $discrepancyProperties = @($discrepancies.SelectNodes('*[local-name()="ChildObjects"]/*[local-name()="Attribute"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
        foreach ($match in [regex]::Matches($fragment, '\bСтрокаРасхождений\.([А-Яа-яЁё]\w+)')) {
            if ($match.Groups[1].Value -notin $discrepancyProperties) {
                $issues.Add("Unknown discrepancy property: $factory.$($match.Groups[1].Value)")
            }
        }
    }
    $goods = $metadata.SelectSingleNode('//*[local-name()="TabularSection"][*[local-name()="Properties"]/*[local-name()="Name"]="Товары"]')
    $goodsProperties = @($goods.SelectNodes('*[local-name()="ChildObjects"]/*[local-name()="Attribute"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
    $fragment += [regex]::Match($bsl, '(?ms)^Процедура ПересчитатьСтроку\(.*?^КонецПроцедуры').Value
    foreach ($match in [regex]::Matches($fragment, '\bСтрокаТоваров\.([А-Яа-яЁё]\w+)')) {
        if ($match.Groups[1].Value -notin $goodsProperties) {
            $issues.Add("Unknown goods property: $factory.$($match.Groups[1].Value)")
        }
    }
}
$formModule = Get-Content -LiteralPath (Join-Path $processor 'Forms/Форма/Ext/Form/Module.bsl') -Raw -Encoding UTF8
$instructionFormModule = Get-Content -LiteralPath (Join-Path $processor 'Forms/Инструкция/Ext/Form/Module.bsl') -Raw -Encoding UTF8
$objectModule = Get-Content -LiteralPath (Join-Path $processor 'Ext/ObjectModule.bsl') -Raw -Encoding UTF8
foreach ($node in $form.SelectNodes('//*[local-name()="Event" or local-name()="Action"]')) {
    if ($formModule -notmatch ('(?m)^Процедура\s+' + [regex]::Escape($node.InnerText) + '\(')) {
        $issues.Add("Missing form handler: $($node.InnerText)")
    }
}
foreach ($node in $instructionForm.SelectNodes('//*[local-name()="Event" or local-name()="Action"]')) {
    if ($instructionFormModule -notmatch ('(?m)^Процедура\s+' + [regex]::Escape($node.InnerText) + '\(')) {
        $issues.Add("Missing instruction form handler: $($node.InnerText)")
    }
}
$backgroundParameter = $form.SelectSingleNode('/*/*[local-name()="Parameters"]/*[local-name()="Parameter" and @name="ДополнительнаяОбработкаСсылка"]')
if ($null -eq $backgroundParameter -or
    $backgroundParameter.SelectSingleNode('*[local-name()="KeyParameter" and text()="true"]') -eq $null) {
    $issues.Add('Missing key form parameter ДополнительнаяОбработкаСсылка')
}
if ($objectModule -notmatch '(?m)^Функция\s+СведенияОВнешнейОбработке\(\)\s+Экспорт' -or
    $objectModule -notmatch '(?m)^Процедура\s+ВыполнитьКоманду\([^)]*\)\s+Экспорт') {
    $issues.Add('Missing BSP external processor registration or background entry point')
}
if ($objectModule -notmatch 'СоглашениеОбъект\.Номер\s*=\s*НомерСоглашения' -or
    $objectModule -notmatch 'Номер,Организация,Партнер,Контрагент') {
    $issues.Add('The customer agreement number is not filled or checked')
}
if ($formModule -notmatch 'ДлительныеОперации\.ВыполнитьФункцию\(' -or
    $formModule -notmatch 'ДополнительныеОтчетыИОбработки\.ВыполнитьКоманду') {
    $issues.Add('The form does not start the external processor through a BSP background job')
}
if ($processorMetadata.SelectSingleNode('//*[local-name()="ChildObjects"]/*[local-name()="Form" and text()="Инструкция"]') -eq $null -or
    $form.SelectSingleNode('/*/*[local-name()="Events"]/*[local-name()="Event" and @name="OnOpen" and text()="ПриОткрытии"]') -eq $null -or
    $formModule -notmatch 'ОткрытьФорму\("ВнешняяОбработка\.СозданиеУКД\.Форма\.Инструкция"') {
    $issues.Add('The HTML instruction form is not registered or opened with the processor')
}
if ($instructionForm.SelectSingleNode('//*[local-name()="HTMLDocumentField" and @name="ПолеИнструкции"]') -eq $null -or
    $instructionForm.SelectSingleNode('/*/*[local-name()="WindowOpeningMode" and text()="LockOwnerWindow"]') -eq $null -or
    $instructionFormModule -notmatch 'HTMLИнструкции\s*=\s*ТекстИнструкции\(\)') {
    $issues.Add('The instruction form does not contain a modal HTML document field')
}
if ($formModule -match 'Подключаемый_СоздатьСледующуюЦепочку') {
    $issues.Add('The old client-side chain scheduler is still present')
}
foreach ($checkedForm in @($form, $instructionForm)) {
    foreach ($scope in @('//*[local-name()="ChildItems"]//*[@id]', '/*/*[local-name()="Attributes"]/*[@id]', '/*/*[local-name()="Commands"]/*[@id]')) {
        $duplicates = $checkedForm.SelectNodes($scope) | Group-Object id | Where-Object Count -gt 1
        foreach ($duplicate in $duplicates) { $issues.Add("Duplicate XML id: $($duplicate.Name)") }
    }
}
if ($bsl -match 'ОбменДанными\.Загрузка\s*=\s*Истина|УстановитьПривилегированныйРежим\(Истина\)') {
    $issues.Add('The processor bypasses business checks or user permissions')
}
# The three document comments are unlimited strings; query equality is invalid.
# Include the rollback query in the integration test, which uses the same fields.
$querySources = $bsl + [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Smoke-Module.bsl'))
# Check direct catalog-query fields, including disabled standard attributes.
foreach ($literal in [regex]::Matches($querySources, '"(?:[^"]|"")*"')) {
    $query = $literal.Value
    foreach ($table in [regex]::Matches($query, 'Справочник\.([А-Яа-яЁё]\w+)\s+КАК\s+([А-Яа-яЁё]\w+)')) {
        $catalogName = $table.Groups[1].Value
        $alias = $table.Groups[2].Value
        $metadata = Read-Metadata 'Catalogs' $catalogName
        $properties = $metadata.MetaDataObject.Catalog.Properties
        $fields = @('Ссылка', 'ПометкаУдаления', 'Предопределенный', 'ИмяПредопределенныхДанных')
        if ([int]$properties.CodeLength -gt 0) { $fields += 'Код' }
        if ([int]$properties.DescriptionLength -gt 0) { $fields += 'Наименование' }
        if ($properties.Hierarchical -eq 'true') {
            $fields += 'Родитель'
            if ($properties.HierarchyType -eq 'HierarchyFoldersAndItems') { $fields += 'ЭтоГруппа' }
        }
        if ($properties.Owners.HasChildNodes) { $fields += 'Владелец' }
        $fields += @($metadata.SelectNodes('/*/*/*[local-name()="ChildObjects"]/*[local-name()="Attribute" or local-name()="TabularSection"]/*[local-name()="Properties"]/*[local-name()="Name"]') | ForEach-Object InnerText)
        foreach ($field in [regex]::Matches($query, '(?<![.\w])' + [regex]::Escape($alias) + '\.([А-Яа-яЁё]\w+)')) {
            if ($field.Groups[1].Value -notin $fields) {
                $issues.Add("Unavailable catalog query field: $catalogName.$($field.Groups[1].Value)")
            }
        }
    }
}
if ($querySources -match 'Комментарий\s*=\s*&Маркер') {
    $issues.Add('Query compares an unlimited-length document comment using equality')
}
# An implicit variable must not resolve to a read-only common module in the context.
$commonModuleNames = @(Get-ChildItem -LiteralPath (Join-Path $configuration 'CommonModules') -File -Filter '*.xml' | ForEach-Object BaseName)
foreach ($match in [regex]::Matches($querySources, '(?m)^\s*([А-Яа-яЁё]\w*)\s*=(?!=)')) {
    if ($match.Groups[1].Value -in $commonModuleNames) {
        $issues.Add("Common-module name used as assignment target: $($match.Groups[1].Value)")
    }
}
if ($issues.Count) { $issues | Sort-Object -Unique | Write-Output; throw 'Source contract validation failed' }
Write-Output 'PASS: metadata contracts, BSP background entry points, form handlers, HTML instruction, XML IDs, comment comparisons and common-module name collisions.'
