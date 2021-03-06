require 'ibotta_geohash/version'

# TODO document encode/decode
# TODO perf test
# TODO compare to C impl

#Pure ruby geohash library
#
# Based on: pr_geohash
# https://github.com/masuidrive/pr_geohash
# Yuichiro MASUI
# Geohash library for pure ruby
# Distributed under the MIT License
#
# Based library is
#// http://github.com/davetroy/geohash-js/blob/master/geohash.js
#// geohash.js
#// Geohash library for Javascript
#// (c) 2008 David Troy
#// Distributed under the MIT License
#
module IbottaGeohash

  #needed for geohash encoding
  BITS = [0x10, 0x08, 0x04, 0x02, 0x01].freeze
  BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz".freeze

  #not sure min is needed
  MERCATOR = (-20037726.37..20037726.37).freeze

  #not sure what these are needed by?
  # WGS84_LAT = (-85.05113..85.05113).freeze
  # WGS84_LON = (-180.0..180.0).freeze

  #needed for bounding box calculations
  EARTH_RADIUS_IN_METERS = 6372797.560856
  DEG_LAT_IN_METERS = 2 * Math::PI * EARTH_RADIUS_IN_METERS / 360
  DEG_TO_RAD = Math::PI / 180.0
  RAD_TO_DEG = 180.0 / Math::PI

  NEIGHBORS = {
    :right  => { :even => "bc01fg45238967deuvhjyznpkmstqrwx", :odd => "p0r21436x8zb9dcf5h7kjnmqesgutwvy" },
    :left   => { :even => "238967debc01fg45kmstqrwxuvhjyznp", :odd => "14365h7k9dcfesgujnmqp0r2twvyx8zb" },
    :top    => { :even => "p0r21436x8zb9dcf5h7kjnmqesgutwvy", :odd => "bc01fg45238967deuvhjyznpkmstqrwx" },
    :bottom => { :even => "14365h7k9dcfesgujnmqp0r2twvyx8zb", :odd => "238967debc01fg45kmstqrwxuvhjyznp" }
  }.freeze

  BORDERS = {
    :right  => { :even => "bcfguvyz", :odd => "prxz" },
    :left   => { :even => "0145hjnp", :odd => "028b" },
    :top    => { :even => "prxz"    , :odd => "bcfguvyz" },
    :bottom => { :even => "028b"    , :odd => "0145hjnp" }
  }.freeze

  class << self

    #decode bounding box from geohash string
    # @todo  reorder bounds?
    # @todo  see if faster way (less array access?)
    # @param [String] geohash string
    # @return [Array<Array>] decoded bounding box [[south latitude, west longitude],[north latitude, east longitude]]
    def decode(geohash)
      #starting bounding box (as if entire world)
      latlng = [[-90.0, 90.0], [-180.0, 180.0]]
      #alternate lat/long (starting at long)
      is_lng = 1
      geohash.downcase.each_char do |c|
        BITS.each do |mask|
          #working on low or high bits?
          lowhigh = (BASE32.index(c) & mask) == 0 ? 1 : 0
          #calculate as half of current box
          latlng[is_lng][lowhigh] = (latlng[is_lng][0] + latlng[is_lng][1]) / 2
          #flip longitude bits
          is_lng ^= 1
        end
      end
      #transpose to low, high lat/long
      latlng.transpose
    end

    #decode center of geohash area
    # @todo  see if faster way? other libs do this first, calc bounding from it
    # @param [String] geohash string
    # @return [Array<Float>] latitude, longitude of center
    def decode_center(geohash)
      res = decode(geohash)
      #get center of each set
      [((res[0][0] + res[1][0]) / 2), ((res[0][1] + res[1][1]) / 2)]
    end

    #Encode latitude and longitude into geohash string
    # @todo  see if faster way? less array access?
    # @param [Float] latitude
    # @param [Float] longitude
    # @param [Integer] precision number of characters
    # @return [String] encoded
    def encode(latitude, longitude, precision=12)
      latlng = [latitude, longitude]
      #start at whole world
      points = [[-90.0, 90.0], [-180.0, 180.0]]
      #alternate lat/long (starting at long)
      is_lng = 1
      #for each character
      (0...precision).map do
        #character value is ch
        ch = 0
        5.times do |bit|
          #get midpoints of current calculation
          mid = (points[is_lng][0] + points[is_lng][1]) / 2
          #min or max value
          minmax = latlng[is_lng] > mid ? 0 : 1
          points[is_lng][minmax] = mid
          #add bits to character
          ch |= BITS[bit] if latlng[is_lng] > mid
          #flip bits
          is_lng ^= 1
        end
        #map value to character
        BASE32[ch,1]
      end.join
    end

    # Calculate each 8 direction neighbors as geohash
    # @param [String] geohash
    # @return [Array<String>] neighbors in clockwise (top, topright, right, ...). Invalid regions at the poles are excluded
    def neighbors(geohash)
      #get all adjacencies (going around)
      [[:top, :right], [:right, :bottom], [:bottom, :left], [:left, :top]].map do |dirs|
        point = adjacent(geohash, dirs[0])
        [point, adjacent(point, dirs[1])]
      end.flatten.compact
    end

    #calculate one adjacent neighbor
    # @param [String] geohash
    # @param [Symbol] dir which direction (top, right, bottom left)
    # @return [String] neighbor in that direction (or nil if invalid)
    def adjacent(geohash, dir)
      #stop recursion if empty
      return if geohash.nil? || geohash.empty?
      #get last character
      base, lastChr = geohash[0..-2], geohash[-1,1]
      type = (geohash.length % 2)==1 ? :odd : :even
      #if bit is border, get adjacency of base hash
      if BORDERS[dir][type].include?(lastChr)
        base = adjacent(base, dir)
        if base.nil?
          return if dir == :top || dir == :bottom
          base = ''
        end
      end
      #add back new neighbor character
      base + BASE32[NEIGHBORS[dir][type].index(lastChr),1]
    end

    #get geohashes covering a radius
    # @param [Float] lat
    # @param [Flaot] lon
    # @param [Float] radius_meters
    # @return [Array<String>] hashes (neighbors and center) covering radius in clockwise (top, topright, right, ...). neighbors not covering radius are excluded
    def areas_by_radius(lat, lon, radius_meters)
      #get min/max latitude and longitude of radius around point
      min_lat, min_lon, max_lat, max_lon = radius_box = bounding_box(lat, lon, radius_meters)

      #estimate the size of boxes to target
      steps = estimate_steps_by_radius(radius_meters)
      #re-encode point using steps
      #the geohashes are composed of 32 distinct numbers/letters, basically base 32
      #bits are composed of 1s and 0s, base 2 or binary
      #steps is the length of the binary number for longitude and latitude, and the combined length of the binary string (which interleaves both the longitude and latitude) is 2*steps
      # since 32 is 2^5, while 2 is 2^1, the length of a base 32 number will be the length of a binary number divided by 5 and plus 1 (32 base 10 = 10000 base 2 = 10 base 32).
      str_len = steps*2/5 + 1
      hash = encode(lat, lon, str_len)

      #get neighbors of box
      neighbors = neighbors(hash)
      neighbors_neighbors = neighbors.each_with_object([]) {|neighbor, nb| nb << neighbors(neighbor)}

      # 25 geohashes surrounding the original
      nb = neighbors_neighbors.flatten.uniq

      # remove those geohashes that are outside the bounding box
      nb.each do |neighbor|
        n_latlng_low, n_latlng_high = decode(neighbor)
        if n_latlng_low[0] > max_lat or n_latlng_low[1] > max_lon or n_latlng_high[0] < min_lat or n_latlng_high[1] < min_lon
          nb -= [neighbor]
        end
      end

      #return remaining neighbor list
      nb
    end

    #estimate steps needed to cover radius
    # @param [Float] radius_meters
    # @return [Integer] steps required
    def estimate_steps_by_radius(radius_meters)
      step = 1
      v = radius_meters
      while v < MERCATOR.max
        v *= 2
        step += 1
      end
      step -= 1
      step
    end

    #get bounding box around a radius
    # NOTE: this breaks down at the poles (which is fine, we stop geocoding at the poles too)
    # NOTE: this this is not WGS84 accurate (does not take into account oblong latitude). But as this is used for
    #   estimation anyway, thats probably fine
    # @todo  reorder return to match decode?
    # @param [Float] lat
    # @param [Float] lon
    # @param [Flaot] radius_meters
    # @return [Array] min_lat, min_long, max_lat, max_long
    def bounding_box(lat, lon, radius_meters)
      radius_meters  = radius_meters.to_f
      delta_lat = radius_meters / DEG_LAT_IN_METERS
      delta_lon = radius_meters / (DEG_LAT_IN_METERS * Math.cos(lat * DEG_TO_RAD))
      [
        lat - delta_lat,
        lon - delta_lon,
        lat + delta_lat,
        lon + delta_lon
      ]
    end

    #haversine distance (distance between two coordinate points) in meters
    def haversine_distance(lat1, lon1, lat2, lon2)
      r = EARTH_RADIUS_IN_METERS
      phi1 = lat1 * DEG_TO_RAD
      phi2 = lat2 * DEG_TO_RAD
      delta_phi= (lat2-lat1) * DEG_TO_RAD
      delta_lambda = (lon2-lon1) * DEG_TO_RAD

      a = Math.sin(delta_phi/2) ** 2 +
          Math.cos(phi1) * Math.cos(phi2) *
          Math.sin(delta_lambda/2) ** 2
      c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
      d = r * c
    end

    def geohash_area(geohash)
      latlngmin, latlngmax = decode(geohash)
      delta_lat_meters = (latlngmax[0] - latlngmin[0]) * DEG_LAT_IN_METERS
      delta_lng_meters = (latlngmax[1] - latlngmin[1]) * (DEG_LAT_IN_METERS * Math.cos(latlngmax[0] * DEG_TO_RAD))
      area = delta_lat_meters * delta_lng_meters
    end

  end

end # module Geohash

#setup class aliases
GeoHash = IbottaGeohash
