# coding: utf-8
RSpec.describe Percy, type: :feature do
  describe '#snapshot', type: :feature, js: true do
    context 'with live sites' do
      it 'snapshots simple HTTPS site' do
        visit 'https://example.com'
        Percy.snapshot(page, "Name")
        visit 'https://percy.io'
        Percy.snapshot(page, "Name 2")
      end
    end
  end
end
