require 'capybara/dsl'
require 'capybara-webkit'
require 'nokogiri'
require 'net/https'
require 'fileutils'

class Southy::Monkey
  Capybara.default_driver = :webkit
  Capybara.app_host = 'http://www.southwest.com'
  include Capybara::DSL

  def lookup(conf, first_name, last_name)
    http = Net::HTTP.new 'www.southwest.com'
    https = Net::HTTP.new 'www.southwest.com', 443
    https.use_ssl = true
    request = Net::HTTP::Post.new '/flight/view-air-reservation.html'
    request.set_form_data :confirmationNumber => conf, :confirmationNumberFirstName => first_name, :confirmationNumberLastName => last_name
    response = https.request request

    while response.is_a? Net::HTTPRedirection
      location = response['Location']
      if location =~ /^https:/
        response = https.request Net::HTTP::Get.new(location)
      else
        response = http.request Net::HTTP::Get.new(location)
      end
    end

    doc = Nokogiri::HTML response.body
    flights = []
    doc.css('.itinerary_container').each do |container|
      container.css('.airProductItineraryTable').each do |node|
        flights << Southy::Flight.from_dom(container, node)
      end
    end
    flights
  end

  def checkin(flight)
    visit '/flight/retrieveCheckinDoc.html?forceNewSession=yes'

    within '#itineraryLookup' do
      fill_in 'confirmationNumber', :with => flight.confirmation_number.ljust(12)
      fill_in 'First Name', :with => flight.first_name.ljust(30)
      fill_in 'Last Name', :with => flight.last_name.ljust(30)
      find('#submitButton').click
    end

    if ! has_css?('#checkinOptions')
      return nil
    end

    within '#checkinOptions' do
      all('input[type="checkbox"]').each {|i| check i[:id] }
      find('#printDocumentsButton').click
    end

    docs = []
    all('.checkinDocument').each do |node|
      doc = Southy::CheckingDocument.parse(node)
      doc.flight = flight
      docs << doc
    end

    docs
  end
end