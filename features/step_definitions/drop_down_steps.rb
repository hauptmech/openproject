Given /^the "(.+)" drop-down should( not)? have the following options:$/ do |id, neg, table|
  meth = neg ? :should_not : :should
  table.raw.each do | option |
    page.send(meth, have_xpath("//select[@id = '#{id}']//option[@value = '#{option[0]}']"))
  end
end

Then /^the "(.+)" drop-down should have the following options (enabled|disabled):$/ do |id, state, table|
  state = state == "disabled" ? "" : "not"
  table.raw.each do | option |
    page.should have_xpath "//select[@id = '#{id}']//option[@value = '#{option[0]}' and #{state}(@disabled)]"
  end
end

Then /^the "(.+)" drop-down(?: within "([^\"]*)")? should have "([^\"]*)" selected$/ do |field_name, selector, option_name|
  with_scope(selector) do
    find_field(field_name).find('option[selected]').text.should == option_name
  end
end
