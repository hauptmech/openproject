require 'spec_helper'

describe JournalsController do
  let(:user) { FactoryGirl.create(:user) }
  let(:project) { FactoryGirl.create(:project_with_trackers) }
  let(:role) { FactoryGirl.create(:role, :permissions => [:view_issues]) }
  let(:member) { FactoryGirl.build(:member, :project => project,
                                        :roles => [role],
                                        :principal => user) }
  let(:issue) { FactoryGirl.build(:issue, :tracker => project.trackers.first,
                                      :author => user,
                                      :project => project,
                                      :description => '') }

  describe "GET diff" do
    render_views

    before do
      issue.update_attribute :description, 'description'
      params = { :id => issue.journals.last.id.to_s, :field => 'description', :format => 'js' }

      get :diff, params
    end

    it { response.should be_success }
    it { response.should render_template("_diff") }
    it { response.body.should == "<div class=\"text-diff\">\n  <ins class=\"diffmod\">description</ins>\n</div>\n" }
  end
end
