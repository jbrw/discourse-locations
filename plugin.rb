# frozen_string_literal: true

# name: discourse-locations
# about: Tools for handling locations in Discourse
# version: 0.1
# authors: Angus McLeod

register_asset 'stylesheets/common/locations.scss'
register_asset 'stylesheets/mobile/locations.scss', :mobile
register_asset 'lib/leaflet/leaflet.css'
register_asset 'lib/leaflet/leaflet.js'
register_asset 'lib/leaflet/leaflet.markercluster.js'
register_asset 'lib/leaflet/MarkerCluster.css'
register_asset 'lib/leaflet/MarkerCluster.Default.css'

Discourse.top_menu_items.push(:map)
Discourse.anonymous_top_menu_items.push(:map)
Discourse.filters.push(:map)
Discourse.anonymous_filters.push(:map)

gem 'geocoder', '1.4.4'

after_initialize do

  if defined?(CustomWizard) == 'constant' && CustomWizard.class == Module
    CustomWizard::Field.add_assets('location', 'discourse-locations', ['components', 'helpers', 'lib', 'stylesheets'])
  end

  Category.register_custom_field_type('location', :json)
  Category.register_custom_field_type('location_enabled', :boolean)
  Category.register_custom_field_type('location_topic_status', :boolean)
  Category.register_custom_field_type('location_map_filter_closed', :boolean)
  add_to_class(:category, :location) { self.custom_fields['location'] }

  add_to_serializer(:basic_category, :location) { object.custom_fields['location'] }
  add_to_serializer(:basic_category, :location_enabled) { object.custom_fields['location_enabled'] }
  add_to_serializer(:basic_category, :location_topic_status) { object.custom_fields['location_topic_status'] }
  add_to_serializer(:basic_category, :location_map_filter_closed) { object.custom_fields['location_map_filter_closed'] }

  Topic.register_custom_field_type('location', :json)
  Topic.register_custom_field_type('has_geo_location', :boolean)
  add_to_class(:topic, :location) { self.custom_fields['location'] }

  add_to_serializer(:topic_view, :location) { object.topic.location }
  add_to_serializer(:topic_view, :include_location?) { object.topic.location.present? }

  TopicList.preloaded_custom_fields << 'location' if TopicList.respond_to? :preloaded_custom_fields
  add_to_serializer(:topic_list_item, :location) { object.location }
  add_to_serializer(:topic_list_item, :include_location?) { object.location.present? }

  PostRevisor.track_topic_field(:location)

  PostRevisor.class_eval do
    track_topic_field(:location) do |tc, location|
      if !location.blank?
        new_location = location.to_unsafe_hash
        tc.record_change('location', tc.topic.custom_fields['location'], new_location)
        tc.topic.custom_fields['location'] = new_location
        tc.topic.custom_fields['has_geo_location'] = !!new_location['geo_location']
      end
    end
  end

  DiscourseEvent.on(:post_created) do |post, opts, _user|
    location = opts[:location].is_a?(String) ? ::JSON.parse(opts[:location]) : opts[:location]
    if post.is_first_post? && location
      topic = Topic.find(post.topic_id)
      topic.custom_fields['location'] = location
      topic.custom_fields['has_geo_location'] = !!location['geo_location']
      topic.save!
    end
  end

  require_dependency 'application_controller'
  module ::Locations
    class Engine < ::Rails::Engine
      engine_name 'locations'
      isolate_namespace Locations
    end
  end

  Locations::Engine.routes.draw do
    get 'search' => 'geo#search'
    get 'country_codes' => 'geo#country_codes'
    get 'validate' => 'geo#validate'
  end

  Discourse::Application.routes.append do
    mount ::Locations::Engine, at: 'location'
  end

  load File.expand_path('../serializers/geo_location.rb', __FILE__)
  load File.expand_path('../lib/country.rb', __FILE__)
  load File.expand_path('../lib/geocode.rb', __FILE__)
  load File.expand_path('../lib/map.rb', __FILE__)
  load File.expand_path('../controllers/geocode.rb', __FILE__)

  unless Rails.env.test?
    begin
      Locations::Geocode.set_provider(SiteSetting.location_geocoding_provider)
    rescue
      SiteSetting.location_geocoding_provider = :nominatim
      Locations::Geocode.set_provider(SiteSetting.location_geocoding_provider)
    end
  end

  add_model_callback(SiteSetting, :before_save) do
    if name == 'location_geocoding_provider'
      Locations::Geocode.set_provider(value)
    end
  end

  require_dependency 'topic_query'
  class ::TopicQuery
    def list_map
      create_list(:map) do |topics|
        topics.joins("INNER JOIN topic_custom_fields
                      ON topic_custom_fields.topic_id = topics.id
                      AND topic_custom_fields.name = 'has_geo_location'")
         Locations::Map.sorted_list_filters.each do |filter|
           topics = filter[:block].call(topics, @options)
         end

         topics
      end
    end
  end

  Locations::Map.add_list_filter do |topics, options|
    if options[:category_id]
      category = Category.find(options[:category_id])
    end

    if SiteSetting.location_map_filter_closed || category.custom_fields['location_map_filter_closed']
      topics = topics.where(closed: false)
    end

    topics
  end

  DiscourseEvent.trigger(:locations_ready)
end
