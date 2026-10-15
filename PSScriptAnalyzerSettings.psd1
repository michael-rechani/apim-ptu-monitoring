@{
  # Scripts are interactive CLI tools; console output is intended. The others are noise here:
  # internal helper names, and parameters used only inside nested functions / test helpers.
  ExcludeRules = @(
    'PSAvoidUsingWriteHost',
    'PSUseSingularNouns',
    'PSUseShouldProcessForStateChangingFunctions',
    'PSReviewUnusedParameter'
  )
}
