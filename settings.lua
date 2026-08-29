data:extend({
  {
    type = "int-setting",
    name = "fpr-update-interval",
    setting_type = "runtime-global",
    default_value = 60,
    minimum_value = 1,
    maximum_value = 3600,
    order = "a"
  },
  {
    type = "bool-setting",
    name = "fpr-debug-logging",
    setting_type = "runtime-global",
    default_value = false,
    order = "b"
  }
})