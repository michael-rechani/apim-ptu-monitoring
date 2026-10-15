@description('Optional. Resource ID of the Microsoft.ApiManagement/service resource to preselect. Leave empty to pick it in the workbook.')
param apimResourceId string = ''

@description('Optional. Resource ID of the Foundry / Azure OpenAI (Microsoft.CognitiveServices/accounts) resource to preselect, to pull PTU usage into this workbook. Leave empty to pick it in the workbook or omit the PTU usage section.')
param aoaiResourceId string = ''

@description('Workbook display name.')
param workbookDisplayName string = 'APIM Gateway Validation'

param location string = resourceGroup().location

// Single source of truth: the same JSON can be pasted into the Workbooks Advanced Editor.
var workbookTemplate = loadTextContent('apim-validation.workbook.json')
var apimParamAnchor = '"id": "p-resource",'
var aoaiParamAnchor = '"id": "p-aoai-resource",'
var withApim = empty(apimResourceId)
  ? workbookTemplate
  : replace(workbookTemplate, apimParamAnchor, '${apimParamAnchor} "value": "${apimResourceId}",')
var serializedWorkbook = empty(aoaiResourceId)
  ? withApim
  : replace(withApim, aoaiParamAnchor, '${aoaiParamAnchor} "value": "${aoaiResourceId}",')

resource apimWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, workbookDisplayName)
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    sourceId: 'azure monitor'
    serializedData: serializedWorkbook
  }
}

output workbookId string = apimWorkbook.id

// False means an anchor in the workbook JSON changed and a resource was NOT preselected.
output resourcesPreselected bool = (empty(apimResourceId) || contains(serializedWorkbook, '"value": "${apimResourceId}"')) && (empty(aoaiResourceId) || contains(serializedWorkbook, '"value": "${aoaiResourceId}"'))
