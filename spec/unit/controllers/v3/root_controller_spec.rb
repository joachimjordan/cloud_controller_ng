require 'rails_helper'

RSpec.describe RootController, type: :controller do
  describe '#v3_root' do
    it 'returns a link to UAA' do
      get :v3_root
      hash = MultiJson.load(response.body)
      expect(hash['links']['uaa']['href']).to eq(TestConfig.config[:uaa][:url])
    end

    it 'returns a link to self' do
      get :v3_root
      hash = MultiJson.load(response.body)
      expected_uri = "#{TestConfig.config[:external_protocol]}://#{TestConfig.config[:external_domain]}/v3"
      expect(hash['links']['self']['href']).to eq(expected_uri)
    end

    it 'returns a link to tasks' do
      get :v3_root
      hash = MultiJson.load(response.body)
      expected_uri = "#{TestConfig.config[:external_protocol]}://#{TestConfig.config[:external_domain]}/v3/tasks"
      expect(hash['links']['tasks']['href']).to eq(expected_uri)
    end
  end
end
