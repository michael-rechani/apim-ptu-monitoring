@description('Optional. Resource ID of the Foundry / Azure OpenAI (Microsoft.CognitiveServices/accounts) resource to preselect. Leave empty to pick it in the workbook.')
param openAiResourceId string = ''

@description('Workbook display name.')
param workbookDisplayName string = 'PTU Validation'

param location string = resourceGroup().location

// Single source of truth: the same JSON can be pasted into the Workbooks Advanced Editor.
var workbookTemplate = loadTextContent('ptu-validation.workbook.json')
var resourceParamAnchor = '"id": "p-resource",'
var serializedWorkbook = empty(openAiResourceId)
  ? workbookTemplate
  : replace(workbookTemplate, resourceParamAnchor, '${resourceParamAnchor} "value": "${openAiResourceId}",')

resource ptuWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
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

output workbookId string = ptuWorkbook.id

// False means the anchor text in the workbook JSON changed and the resource was NOT preselected.
output resourcePreselected bool = empty(openAiResourceId) || contains(serializedWorkbook, '"value": "${openAiResourceId}"')
