# frozen_string_literal: true

require 'aws-sdk-autoscaling'

module Capistrano
  module ASG
    module Rolling
      # AWS EC2 Auto Scaling Group.
      class AutoscaleGroup
        include AWS

        LIFECYCLE_STATE_IN_SERVICE = 'InService'
        LIFECYCLE_STATE_STANDBY = 'Standby'

        COMPLETED_REFRESH_STATUSES = %w[Successful Failed Cancelled RollbackSuccessful RollbackFailed].freeze
        FAILED_REFRESH_STATUS = 'Failed'

        attr_reader :name, :properties, :refresh_id

        def initialize(name, properties = {})
          @name = name
          @properties = properties

          if properties[:healthy_percentage]
            properties[:min_healthy_percentage] = properties.delete(:healthy_percentage)

            Kernel.warn('WARNING: the property `healthy_percentage` is deprecated and will be removed in a future release. Please update to `min_healthy_percentage`.')
          end

          validate_properties!
        end

        def exists?
          aws_autoscaling_group.exists?
        end

        def launch_template
          @launch_template ||= begin
            template = aws_autoscaling_group.launch_template
            raise Capistrano::ASG::Rolling::NoLaunchTemplate if template.nil?

            LaunchTemplate.new(template.launch_template_id, template.version, template.launch_template_name)
          end
        end

        def subnet_ids
          aws_autoscaling_group.vpc_zone_identifier.split(',')
        end

        def instance_warmup_time
          aws_autoscaling_group.health_check_grace_period
        end

        def min_healthy_percentage
          properties.fetch(:min_healthy_percentage, nil)
        end

        def max_healthy_percentage
          properties.fetch(:max_healthy_percentage, nil)
        end

        def start_instance_refresh(launch_template)
          @refresh_id = aws_autoscaling_client.start_instance_refresh(
            auto_scaling_group_name: name,
            strategy: 'Rolling',
            desired_configuration: {
              launch_template: {
                launch_template_id: launch_template.id,
                version: launch_template.version
              }
            },
            preferences: {
              instance_warmup: instance_warmup_time,
              skip_matching: true,
              min_healthy_percentage: min_healthy_percentage,
              max_healthy_percentage: max_healthy_percentage
            }.compact
          ).instance_refresh_id
        rescue Aws::AutoScaling::Errors::InstanceRefreshInProgress => e
          raise Capistrano::ASG::Rolling::StartInstanceRefreshError, e
        end

        InstanceRefreshStatus = Struct.new(:status, :percentage_complete) do
          def completed?
            COMPLETED_REFRESH_STATUSES.include?(status)
          end

          def failed?
            status == FAILED_REFRESH_STATUS
          end
        end

        def latest_instance_refresh
          instance_refresh = most_recent_instance_refresh
          status = instance_refresh&.dig(:status)
          percentage_complete = instance_refresh&.dig(:percentage_complete)
          return nil if status.nil?

          InstanceRefreshStatus.new(status, percentage_complete)
        end

        # Returns instances with lifecycle state "InService" for this Auto Scaling Group.
        def instances
          instance_ids = aws_autoscaling_group.instances.select { |i| i.lifecycle_state == LIFECYCLE_STATE_IN_SERVICE }.map(&:instance_id)
          return [] if instance_ids.empty?

          response = aws_ec2_client.describe_instances(instance_ids: instance_ids)
          response.reservations.flat_map(&:instances).map do |instance|
            Instance.new(instance.instance_id, instance.private_ip_address, instance.public_ip_address, instance.image_id, self)
          end
        end

        def enter_standby(instance)
          instance = aws_autoscaling_group.instances.find { |i| i.id == instance.id }
          return if instance.nil?

          instance.enter_standby(should_decrement_desired_capacity: true)

          loop do
            instance.load
            break if instance.lifecycle_state == LIFECYCLE_STATE_STANDBY

            sleep 1
          end
        end

        def exit_standby(instance)
          instance = aws_autoscaling_group.instances.find { |i| i.id == instance.id }
          return if instance.nil?

          instance.exit_standby
        end

        def rolling?
          properties.fetch(:rolling, true)
        end

        def name_tag
          "Deployment for #{name}"
        end

        private

        def most_recent_instance_refresh
          parameters = {
            auto_scaling_group_name: name,
            max_records: 1
          }
          parameters[:instance_refresh_ids] = [@refresh_id] if @refresh_id
          refresh = aws_autoscaling_client.describe_instance_refreshes(parameters).to_h
          refresh[:instance_refreshes].first
        end

        def aws_autoscaling_group
          @aws_autoscaling_group ||= ::Aws::AutoScaling::AutoScalingGroup.new(name: name, client: aws_autoscaling_client)
        end

        def validate_properties!
          raise ArgumentError, 'Property `min_healthy_percentage` must be between 0-100.' if min_healthy_percentage && !(0..100).cover?(min_healthy_percentage)

          if max_healthy_percentage
            raise ArgumentError, 'Property `max_healthy_percentage` must be between 100-200.' unless (100..200).cover?(max_healthy_percentage)

            if min_healthy_percentage
              diff = max_healthy_percentage - min_healthy_percentage
              raise ArgumentError, 'The difference between `min_healthy_percentage` and `max_healthy_percentage` must not be greater than 100.' if diff > 100
            else
              raise ArgumentError, 'Property `min_healthy_percentage` must be specified when using `max_healthy_percentage`.'
            end
          end
        end
      end
    end
  end
end
