###
  Pokemon Go(c) MITM node proxy
  by Michael Strassburger <codepoet@cpan.org>

  This example just dumps all in-/outgoing messages and responses plus all envelopes and signatures

###

PokemonGoMITM = require './lib/pokemon-go-mitm'
pcrypt = require 'pcrypt'
changeCase = require 'change-case'
moment = require 'moment'
LatLon = require('geodesy').LatLonSpherical

# Uncomment if you want to filter the regular messages
# ignore = ['GetHatchedEggs', 'DownloadSettings', 'GetInventory', 'CheckAwardedBadges', 'GetMapObjects']
ignore = []

pokemons = []
currentLocation = null
mapRadius = 150 # Approx size of level 15 s2 cell

forts = null
currentLocation = null

server = new PokemonGoMITM port: 8081, debug: true
	.addRequestEnvelopeHandler (data) ->
		console.log "[#] Request Envelope", JSON.stringify(data, null, 4)
		false

	.addResponseEnvelopeHandler (data) ->
		console.log "[#] Response Envelope", JSON.stringify(data, null, 4)
		false

	.addRequestEnvelopeHandler (data) ->
		# TODO: update once repeated field 6 is parsed
		return false unless data.unknown6[0]?.unknown2?.encrypted_signature

		buffer = pcrypt.decrypt data.unknown6[0]?.unknown2?.encrypted_signature
		decoded = @parseProtobuf buffer, 'POGOProtos.Networking.Envelopes.Signature'
		console.log "[@] Request Envelope Signature", JSON.stringify(decoded, null, 4)
		false

	.addResponseHandler "CatchPokemon", (data) ->
		data.status = 'CATCH_FLEE' if data.status is 'CATCH_SUCCESS'
		data

	.addResponseHandler "DownloadSettings", (data) ->
		if data.settings
			data.settings.map_settings.pokemon_visible_range = 1500
			data.settings.map_settings.poke_nav_range_meters = 1500
			data.settings.map_settings.encounter_range_meters = 1500
			data.settings.fort_settings.interaction_range_meters = 1500
			data.settings.fort_settings.max_total_deployed_pokemon = 50
		data

	# Fetch our current location as soon as it gets passed to the API
	.addRequestHandler "GetMapObjects", (data) ->
		currentLocation = new LatLon data.latitude, data.longitude
		console.log "[+] Current position of the player #{currentLocation}"
		false

	# Parse the wild pokemons nearby
	.addResponseHandler "GetMapObjects", (data) ->
		return false if not data.map_cells.length

		oldPokemons = pokemons
		pokemons = []
		seen = {}

		# Store wild pokemons
		addPokemon = (pokemon) ->
			return if seen[pokemon.encounter_id]
			return if pokemon.time_till_hidden_ms < 0

			console.log "new wild pokemon", pokemon
			pokemons.push pokemon
			seen[pokemon.encounter_id] = pokemon

		for cell in data.map_cells
			addPokemon pokemon for pokemon in cell.wild_pokemons

		# Use server timestamp
		timestampMs = Number(data.map_cells[0].current_timestamp_ms)
		# Add previously known pokemon, unless expired
		for pokemon in oldPokemons when not seen[pokemon.encounter_id]
			expirationMs = Number(pokemon.last_modified_timestamp_ms) + pokemon.time_till_hidden_ms
			pokemons.push pokemon unless expirationMs < timestampMs
			seen[pokemon.encounter_id] = pokemon

		# Correct steps display for known nearby Pokémon (idea by @zaksabeast)
		return false if not currentLocation
		for cell in data.map_cells
			for nearby in cell.nearby_pokemons when seen[nearby.encounter_id]
				pokemon = seen[nearby.encounter_id]
				position = new LatLon pokemon.latitude, pokemon.longitude
				nearby.distance_in_meters = Math.floor currentLocation.distanceTo position
		data

	# Whenever a poke spot is opened, populate it with the radar info!
	.addResponseHandler "FortDetails", (data) ->
		console.log "fetched fort request", data
		info = ""

		# Populate some neat info about the pokemon's whereabouts
		pokemonInfo = (pokemon) ->
			name = changeCase.titleCase pokemon.pokemon_data.pokemon_id
			name = name.replace(" Male", "♂").replace(" Female", "♀")
			expirationMs = Number(pokemon.last_modified_timestamp_ms) + pokemon.time_till_hidden_ms
			position = new LatLon pokemon.latitude, pokemon.longitude
			expires = moment(expirationMs).fromNow()
			distance = Math.floor currentLocation.distanceTo position
			bearing = currentLocation.bearingTo position
			direction = switch true
				when bearing>330 then "↑"
				when bearing>285 then "↖"
				when bearing>240 then "←"
				when bearing>195 then "↙"
				when bearing>150 then "↓"
				when bearing>105 then "↘"
				when bearing>60 then "→"
				when bearing>15 then "↗"
				else "↑"

			"#{name} #{direction} #{distance}m expires #{expires}"

		# Create map marker for pokemon location
		markers = {}
		addMarker = (id, lat, lon) ->
			label = id.charAt(0)
			name = changeCase.paramCase id.replace(/_([MF]).*/, "_$1")
			icon = "http://raw.github.com/msikma/pokesprite/master/icons/pokemon/regular/#{name}.png"
			markers[id] = "&markers=label:#{label}%7Cicon:#{icon}" if not markers[id]
			markers[id] += "%7C#{lat},#{lon}"

		for modifier in data.modifiers when modifier.item_id is 'ITEM_TROY_DISK'
			expires = moment(Number(modifier.expiration_timestamp_ms)).fromNow()
			info += "Lure by #{modifier.deployer_player_codename} expires #{expires}\n"

		mapPokemons = []
		if currentLocation
			# Limit to map radius
			for pokemon in pokemons
				position = new LatLon pokemon.latitude, pokemon.longitude
				if mapRadius > currentLocation.distanceTo position
					mapPokemons.push pokemon
					addMarker(pokemon.pokemon_data.pokemon_id, pokemon.latitude, pokemon.longitude)

			# Create map image url
			loc = "#{currentLocation.lat},#{currentLocation.lon}"
			img = "http://maps.googleapis.com/maps/api/staticmap?" +
				"center=#{loc}&zoom=17&size=384x512&markers=color:blue%7Csize:tiny%7C#{loc}"
			img += (marker for id, marker of markers).join ""
			data.image_urls.unshift img

			# Sort pokemons by distance
			mapPokemons.sort (p1, p2) ->
				d1 = currentLocation.distanceTo new LatLon(p1.latitude, p1.longitude)
				d2 = currentLocation.distanceTo new LatLon(p2.latitude, p2.longitude)
				d1 - d2


		info += if mapPokemons.length
			(pokemonInfo(pokemon) for pokemon in mapPokemons).join "\n"
		else
			"No wild Pokémon near you..."
		data.description = info
		data

	# Always get the full inventory
	#.addRequestHandler "GetInventory", (data) ->
	#	data.last_timestamp_ms = 0
	#	data

	# Append IV% to existing Pokémon names
	.addResponseHandler "GetInventory", (data) ->
		if data.inventory_delta
			for item in data.inventory_delta.inventory_items when item.inventory_item_data
				if pokemon = item.inventory_item_data.pokemon_data
					id = changeCase.titleCase pokemon.pokemon_id
					name = pokemon.nickname or id.replace(" Male", "♂").replace(" Female", "♀")
					atk = pokemon.individual_attack or 0
					def = pokemon.individual_defense or 0
					sta = pokemon.individual_stamina or 0
					iv = Math.round((atk + def + sta) * 100/45)
					pokemon.nickname = "#{name} #{iv}%"

		data

	.addResponseHandler "EvolvePokemon", (data) ->
		data.result = 'FAILED_POKEMON_MISSING' if data.result is 'SUCCESS'
		data

	.addResponseHandler "GetMapObjects", (data) ->
		forts = []
		for cell in data.map_cells
			for fort in cell.forts
				forts.push fort
				zfta = parseInt((parseFloat(fort.cooldown_complete_timestamp_ms) - parseFloat(new Date().getTime())) / 1000)
				if zfta <= 0
					console.log "PokeStop '#{fort.id}' is ready!"
		false
	.addResponseHandler "FortDetails", (data) ->
		info = ""
		for fort in forts
			if data.fort_id == fort.id
				if fort.cooldown_complete_timestamp_ms > 0
					zexpir = moment(Number(fort.cooldown_complete_timestamp_ms)).fromNow()
					ztda = parseInt((parseFloat(fort.cooldown_complete_timestamp_ms) - parseFloat(new Date().getTime())) / 1000)
					if ztda > 0
						info += "Ready in #{ztda} seconds (#{zexpir})\n"
					else
						console.log "PokeStop '#{data.name}' is ready!"
				break
		data.description = info
		data
