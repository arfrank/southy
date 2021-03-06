require 'json'
require 'net/https'
require 'fileutils'
require 'pp'
require 'tzinfo'
require 'ostruct'

class Southy::Monkey

  DEBUG = false

  def initialize(config = nil)
    @config = config

    @hostname = 'mobile.southwest.com'
    @api_key = 'l7xx0a43088fe6254712b10787646d1b298e'

    @https = Net::HTTP.new @hostname, 443
    @https.use_ssl = true
    @https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    @https.verify_depth = 5
  end

  def parse_json(conf, response, name)
    if response.body == nil || response.body == ''
      @config.log "Empty response body returned"
      return { 'errmsg' => "empty response body - #{response.code} (#{response.msg})"}
    end

    json = JSON.parse response.body
    @config.save_file conf, "#{name}.json", json

    JSON.parse response.body, object_class: OpenStruct
  end

  def validate_airport_code(code)
    if Southy::Airport.lookup code
      true
    else
      @config.log "Unknown airport code: #{code}"
      false
    end
  end

  def alternate_names(first, last)
    f, l = first.split(' '), last.split(' ')
    if f.length == 1 && l.length == 2
      return [ "#{f[0]} #{l[0]}", l[1] ]
    elsif f.length == 2 && l.length == 1
      return [ f[0], "#{f[1]} #{l[0]}" ]
    end
    [ first, last ]
  end

  def fetch_trip_info(conf, first_name, last_name)
    uri = URI("https://#{@hostname}/api/mobile-air-booking/v1/mobile-air-booking/page/view-reservation/#{conf}")
    uri.query = URI.encode_www_form(
      'first-name' => first_name,
      'last-name'  => last_name
    )
    request = Net::HTTP::Get.new uri
    fetch_json conf, request, 'trip-info'
  end

  def lookup(conf, first_name, last_name)
    json = fetch_trip_info conf, first_name, last_name

    statusCode = json.httpStatusCode

    if statusCode == 'NOT_FOUND'
      alternate_names(first_name, last_name).tap do |alt_first, alt_last|
        if alt_first != first_name || alt_last != last_name
          json = fetch_trip_info conf, alt_first, alt_last
        end
      end
    end

    statusCode = json.httpStatusCode
    code = json.code
    message = json.message

    if statusCode
      ident = "#{conf} #{first_name} #{last_name}"
      @config.log "Error looking up flights for #{ident} - #{statusCode} / #{code} - #{message}"
    end

    if statusCode == 'BAD_REQUEST'
      return { error: 'invalid', reason: message, flights: [] }
    end

    if statusCode == 'NOT_FOUND'
      return { error: 'notfound', reason: message, flights: [] }
    end

    if statusCode == 'INTERNAL_SERVER_ERROR'
      return { error: 'internal error', reason: message, flights: [] }
    end

    page = json.viewReservationViewPage
    return { error: 'failure', reason: 'no reservation', flights: [] } unless page

    bounds = page.bounds
    return { error: 'failure', reason: 'no flights', flights: [] } unless bounds

    passengers = page.passengers
    return { error: 'failure', reason: 'no passengers', flights: [] } unless passengers

    response = { error: nil, flights: {} }
    bounds.each do |bound|
      flights = bound.flights
      stops   = bound.stops
      flights.each_with_index do |flight, i|

        if i == 0
          depart_code = bound.departureAirport.code
          depart_time = bound.departureTime
        else
          depart_code = stops[i-1].airport.code
          depart_time = stops[i-1].departureTime
        end

        if i == flights.length - 1
          arrive_code = bound.arrivalAirport.code
        else
          arrive_code = stops[i-1].airport.code
        end

        next unless validate_airport_code(depart_code) && validate_airport_code(arrive_code)

        depart_airport = Southy::Airport.lookup depart_code
        arrive_airport = Southy::Airport.lookup arrive_code

        tz          = TZInfo::Timezone.get depart_airport.timezone
        utc         = tz.local_to_utc DateTime.parse("#{bound.departureDate} #{depart_time}")
        depart_date = Southy::Flight.local_date_time utc, depart_code

        passengers.each do |passenger|
          names = passenger.name.split ' '

          f = Southy::Flight.new
          f.confirmation_number = conf
          f.first_name          = names.first.capitalize
          f.last_name           = names.last.capitalize
          f.number              = flight.number
          f.depart_date         = depart_date
          f.depart_code         = depart_code
          f.depart_airport      = depart_airport.name
          f.arrive_code         = arrive_code
          f.arrive_airport      = arrive_airport.name

          response[:flights][conf] ||= []
          response[:flights][conf] << f
        end
      end
    end

    response
  end

  def fetch_checkin_info_1(conf, first_name, last_name)
    uri = URI("https://#{@hostname}/api/mobile-air-operations/v1/mobile-air-operations/page/check-in/#{conf}")
    uri.query = URI.encode_www_form(
      'first-name' => first_name,
      'last-name'  => last_name
    )
    request = Net::HTTP::Get.new uri
    fetch_json conf, request, 'checkin-info-1'
  end

  def fetch_checkin_info_2(conf, first_name, last_name, sessionToken)
    uri = URI("https://#{@hostname}/api/mobile-air-operations/v1/mobile-air-operations/page/check-in")
    request = Net::HTTP::Post.new uri
    request.body = {
      recordLocator: conf,
      firstName: first_name,
      lastName: last_name,
      checkInSessionToken: sessionToken
    }.to_json
    request.content_type = 'application/json'
    fetch_json conf, request, "checkin-info-2--#{first_name.downcase}-#{last_name.downcase}"
  end

  def checkin(flights)
    checked_in_flights = []
    flight = flights[0]
    json = fetch_checkin_info_1 flight.confirmation_number, flight.first_name, flight.last_name
    sessionToken = json.checkInSessionToken

    json = fetch_checkin_info_2 flight.confirmation_number, flight.first_name, flight.last_name, sessionToken

    errmsg = json.errmsg
    if errmsg
      @config.log "Error checking in passengers: #{errmsg}"
      puts errmsg
      return { flights: [] }
    end

    page = json.checkInConfirmationPage
    unless page
      @config.log "Could not find checkin information for #{flight.conf}"
      puts "No checkin information"
      return { flight: [] }
    end

    flightNodes = page.flights

    flightNodes.each do |flightNode|
      num = flightNode.flightNumber

      passengers = flightNode.passengers
      passengers.each do |passenger|
        name = passenger.name

        existing = flights.find { |f| f.number == num && f.full_name == name }
        if existing
          existing.group = passenger.boardingGroup
          existing.position = passenger.boardingPosition
          checked_in_flights << existing
        end
      end
    end

    { :flights => checked_in_flights.compact }
  end

  private

  def fetch_json(conf, request, name, n=0)
    puts "Fetch #{request.path}" if DEBUG
    request['User-Agent'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 8_0 like Mac OS X) AppleWebKit/600.1.3 (KHTML, like Gecko) Version/8.0 Mobile/12A4345d Safari/600.1.4'
    request['X-API-Key'] = @api_key

    response = @https.request(request)

    json = parse_json conf, response, name

    if json.errmsg && json.opstatus && json.opstatus != 0 && n <= 10  # technical error, try again (for a while)
      fetch_json conf, request, name, n + 1
    else
      json
    end
  end
end

class Southy::TestMonkey < Southy::Monkey
  def get_json(conf, name)
    base = File.dirname(__FILE__) + "/../../test/fixtures/#{conf}/#{name}"
    last = "#{base}.json"
    n = 1
    while File.exist? "#{base}_#{n}.json"
      last = "#{base}_#{n}.json"
      n += 1
    end
    JSON.parse IO.read(last).strip, object_class: OpenStruct
  end

  def fetch_trip_info(conf, first_name, last_name)
    get_json conf, "trip-info"
  end
end
