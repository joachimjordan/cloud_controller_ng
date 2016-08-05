require 'spec_helper'

module VCAP::CloudController
  RSpec.describe VCAP::CloudController::ServiceBinding, type: :model do
    it { is_expected.to have_timestamp_columns }

    describe 'Associations' do
      it { is_expected.to have_associated :app, associated_instance: ->(binding) { AppFactory.make(space: binding.space) } }
      it { is_expected.to have_associated :service_instance, associated_instance: ->(binding) { ServiceInstance.make(space: binding.space) } }
    end

    describe 'Validations' do
      it { is_expected.to validate_presence :app }
      it { is_expected.to validate_presence :service_instance }
      it { is_expected.to validate_db_presence :credentials }
      it { is_expected.to validate_uniqueness [:app_id, :service_instance_id] }

      it 'validates max length of volume_mounts' do
        too_long = 'a' * (65_535 + 1)

        binding = ServiceBinding.make
        binding.volume_mounts = too_long

        expect { binding.save }.to raise_error(Sequel::ValidationFailed, /volume_mounts max_length/)
      end

      describe 'changing the binding after creation' do
        subject(:binding) { ServiceBinding.make }

        describe 'the associated app' do
          it 'allows changing to the same app' do
            binding.app = binding.app
            expect { binding.save }.not_to raise_error
          end

          it 'does not allow changing app after it has been set' do
            binding.app = AppFactory.make(space: binding.app.space)
            expect { binding.save }.to raise_error Sequel::ValidationFailed, /app/
          end
        end

        describe 'the associated service instance' do
          it 'allows changing to the same service instance' do
            binding.service_instance = binding.service_instance
            expect { binding.save }.not_to raise_error
          end

          it 'does not allow changing service_instance after it has been set' do
            binding.service_instance = ServiceInstance.make(space: binding.app.space)
            expect { binding.save }.to raise_error Sequel::ValidationFailed, /service_instance/
          end
        end
      end
    end

    describe 'Serialization' do
      it { is_expected.to import_attributes :app_guid, :service_instance_guid, :credentials, :syslog_drain_url }
    end

    describe '#new' do
      it 'has a guid when constructed' do
        binding = described_class.new
        expect(binding.guid).to be
      end
    end

    describe 'encrypted columns' do
      describe 'credentials' do
        it_behaves_like 'a model with an encrypted attribute' do
          let(:service_instance) { ManagedServiceInstance.make }

          def new_model
            ServiceBinding.make(
              service_instance: service_instance,
              credentials: value_to_encrypt
            )
          end

          let(:encrypted_attr) { :credentials }
          let(:attr_salt) { :salt }
        end
      end

      describe 'volume_mounts' do
        it_behaves_like 'a model with an encrypted attribute' do
          let(:service_instance) { ManagedServiceInstance.make }

          def new_model
            ServiceBinding.make(
              service_instance: service_instance,
              volume_mounts: value_to_encrypt
            )
          end

          let(:encrypted_attr) { :volume_mounts }
        end
      end
    end

    describe 'bad relationships' do
      before do
        # since we don't set them, these will have different app spaces
        @service_instance = ManagedServiceInstance.make
        @app = AppFactory.make
        @service_binding = ServiceBinding.make
      end

      it 'should not associate an app with a service from a different app space' do
        expect {
          service_binding = ServiceBinding.make
          service_binding.app = @app
          service_binding.save
        }.to raise_error ServiceBinding::InvalidAppAndServiceRelation
      end

      it 'should not associate a service with an app from a different app space' do
        expect {
          service_binding = ServiceBinding.make
          service_binding.service_instance = @service_instance
          service_binding.save
        }.to raise_error ServiceBinding::InvalidAppAndServiceRelation
      end
    end

    describe '#in_suspended_org?' do
      let(:app) { VCAP::CloudController::App.make }
      subject(:service_binding) {  VCAP::CloudController::ServiceBinding.new(app: app) }

      context 'when in a suspended organization' do
        before { allow(app).to receive(:in_suspended_org?).and_return(true) }
        it 'is true' do
          expect(service_binding).to be_in_suspended_org
        end
      end

      context 'when in an unsuspended organization' do
        before { allow(app).to receive(:in_suspended_org?).and_return(false) }
        it 'is false' do
          expect(service_binding).not_to be_in_suspended_org
        end
      end
    end

    describe 'logging service bindings' do
      let(:service) { Service.make }
      let(:service_plan) { ServicePlan.make(service: service) }
      let(:service_instance) do
        ManagedServiceInstance.make(
          service_plan: service_plan,
          name: 'not a syslog drain instance'
        )
      end

      context 'service that does not require syslog_drain' do
        let(:service) { Service.make(requires: []) }

        it 'should allow a non syslog_drain with a nil syslog drain url' do
          expect {
            service_binding = ServiceBinding.make(service_instance: service_instance)
            service_binding.syslog_drain_url = nil
            service_binding.save
          }.not_to raise_error
        end

        it 'should allow a non syslog_drain with an empty syslog drain url' do
          expect {
            service_binding = ServiceBinding.make(service_instance: service_instance)
            service_binding.syslog_drain_url = ''
            service_binding.save
          }.not_to raise_error
        end
      end

      context 'service that does require a syslog_drain' do
        let(:service) { Service.make(requires: ['syslog_drain']) }

        it 'should allow a syslog_drain with a syslog drain url' do
          expect {
            service_binding = ServiceBinding.make(service_instance: service_instance)
            service_binding.syslog_drain_url = 'http://syslogurl.com'
            service_binding.save
          }.not_to raise_error
        end
      end
    end

    describe 'restaging' do
      let(:app) { AppFactory.make(state: 'STARTED', instances: 1) }

      let(:service_instance) { ManagedServiceInstance.make(space: app.space) }

      it 'should not trigger restaging when creating a binding' do
        ServiceBinding.make(app: app, service_instance: service_instance)
        app.refresh
        expect(app.needs_staging?).to be false
      end

      it 'should not trigger restaging when directly destroying a binding' do
        binding = ServiceBinding.make(app: app, service_instance: service_instance)
        expect { binding.destroy }.not_to change { app.refresh.needs_staging? }.from(false)
      end

      context 'when indirectly destroying a binding' do
        let(:binding) { ServiceBinding.make(app: app, service_instance: service_instance) }

        it 'should not trigger restaging if the broker successfully unbinds' do
          stub_unbind(binding, status: 200)
          expect { app.remove_service_binding(binding) }.not_to change { app.refresh.needs_staging? }.from(false)
        end

        it 'should raise a broker error if the broker cannot successfully unbind' do
          stub_unbind(binding, status: 500)

          expect {
            app.remove_service_binding(binding)
          }.to raise_error(VCAP::Services::ServiceBrokers::V2::Errors::ServiceBrokerBadResponse)
        end
      end
    end

    describe 'user_visibility_filter' do
      let!(:service_instance) { ManagedServiceInstance.make }
      let!(:service_binding) { ServiceBinding.make(service_instance: service_instance) }
      let!(:other_binding) { ServiceBinding.make }
      let(:developer) { make_developer_for_space(service_instance.space) }
      let(:auditor) { make_auditor_for_space(service_instance.space) }
      let(:other_user) { User.make }

      it 'has the same rules as ServiceInstances' do
        visible_to_developer = ServiceBinding.user_visible(developer)
        visible_to_auditor = ServiceBinding.user_visible(auditor)
        visible_to_other_user = ServiceBinding.user_visible(other_user)

        expect(visible_to_developer.all).to eq [service_binding]
        expect(visible_to_auditor.all).to eq [service_binding]
        expect(visible_to_other_user.all).to be_empty
      end
    end
  end
end
