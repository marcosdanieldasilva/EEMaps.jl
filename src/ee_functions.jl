using Parameters, Bonito
using GeoArtifacts, GeoIO, GeoTables, GeoJSON, JSON3, DataFrames, Statistics

@with_kw struct Layer
  # -- Data Source --
  data::String                                        # GeoJSON (as a string) or tile URL
  name::String = ""                                   # Layer name
  shown::Bool = true                                  # Initial visibility
  opacity::Float64 = 1.0                              # Overall layer opacity

  # -- Vector style options (for L.geoJSON) --
  color::Union{Nothing,String} = nothing              # Stroke color
  weight::Union{Nothing,Int} = nothing                # Stroke width (in pixels)
  fillColor::Union{Nothing,String} = nothing          # Fill color
  fillOpacity::Union{Nothing,Float64} = nothing       # Fill opacity (0.0–1.0)
  dashArray::Union{Nothing,String} = nothing          # Dash pattern (e.g. "5,10")
  multicolor::Union{Nothing,Bool} = nothing            # If true, apply dynamic per-feature coloring

  # -- Tile layer options (for L.tileLayer) --
  attribution::Union{Nothing,String} = nothing        # Attribution HTML text
  minZoom::Union{Nothing,Int} = nothing               # Minimum zoom level
  maxZoom::Union{Nothing,Int} = nothing               # Maximum zoom level
  subdomains::Union{Nothing,Vector{String}} = nothing # Tile subdomains

  # -- Earth Engine visualization parameters --
  min::Union{Nothing,Real} = nothing                  # Stretch minimum value
  max::Union{Nothing,Real} = nothing                  # Stretch maximum value
  bands::Union{Nothing,Vector{String}} = nothing      # List of bands (e.g. ["B4", "B3", "B2"])
  palette::Union{Nothing,Vector{String}} = nothing    # Color palette
  gain::Union{Nothing,Real} = nothing                 # Gain factor
  bias::Union{Nothing,Real} = nothing                 # Bias offset
  gamma::Union{Nothing,Real} = nothing                # Gamma correction
end

# Converts a geotable to GeoJSON (returns the JSON object as a serialized string).
function geotable_to_geojson(geotable::AbstractGeoTable)
  io = IOBuffer()
  GeoJSON.write(io, geotable)
  return String(take!(io))
end

const gee_keys = Set([:min, :max, :bands, :palette, :gain, :bias, :gamma])

"""
    eeobject_to_url(obj::PyObject; kwargs...)

Converts an Earth Engine object (Feature, FeatureCollection, Image or ImageCollection)
into a tile URL template. Only the visualization parameters defined in `gee_keys` are accepted.
"""
function eeobject_to_url(obj::PyObject; kwargs...)
  # Check if the object is one of the supported types.
  if !(pyisinstance(obj, ee.Feature) ||
       pyisinstance(obj, ee.FeatureCollection) ||
       pyisinstance(obj, ee.Image) ||
       pyisinstance(obj, ee.ImageCollection))
    error("Unsupported ee object type. Use ee.Feature, ee.FeatureCollection, ee.Image or ee.ImageCollection.")
  end

  # Create a dictionary of parameters, initializing each with `missing`.
  visParams = Dict{Symbol,Any}(k => missing for k in gee_keys)

  # Override with any provided keyword arguments (if in gee_keys).
  for (k, v) in kwargs
    if k in gee_keys
      visParams[k] = v
    end
  end

  # Remove entries with missing values.
  filtered = Dict(string(k) => v for (k, v) in visParams if v !== missing)

  # Obtain the Map ID dictionary and return the tile URL template.
  map_id_dict = obj.getMapId(filtered)
  return map_id_dict["tile_fetcher"].url_format
end

# Check if a string is a valid tile URL.
function is_valid_tile_url(url::String)
  # A simple check: the url should start with "https://" and contain the tile placeholders.
  return startswith(url, "https://") && occursin("{x}", url) && occursin("{y}", url) && occursin("{z}", url)
end

"""
    layer(data::Union{AbstractGeoTable,PyObject,String}; kwargs...)

Construct a `Layer` by wrapping the given data source together with any number
of styling or visualization options supplied as keyword arguments.

# Arguments
- `data`
  - A GeoJSON-serializable object for vector layers
  - A `String` URL template for tile layers
  - A `PyObject` (e.g. an Earth Engine Image) for EE layers
- `kwargs`
  - **Vector style options** (for `L.geoJSON`):
    - `:color::String` — stroke (border) color (e.g. `"#3388ff"`)
    - `:weight::Int` — stroke width in pixels
    - `:fillColor::String` — fill color
    - `:fillOpacity::Float64` — fill opacity (0.0-1.0)
    - `:dashArray::String` — dash pattern (e.g. `"5,10"`)
    - `:multicolor::Bool` — if `true`, apply dynamic per-feature coloring
  - **Tile layer options** (for `L.tileLayer`):
    - `:attribution::String` — attribution HTML
    - `:minZoom::Int` — minimum zoom level
    - `:maxZoom::Int` — maximum zoom level
    - `:subdomains::Vector{String}` — subdomain templates (e.g. `["a","b","c"]`)
  - **Earth Engine visualization parameters** (for `ee.Image.getMapId(visParams)`):
    - `:min::Real` — lower bound for stretching (e.g. `0`)
    - `:max::Real` — upper bound for stretching (e.g. `3000`)
    - `:bands::Vector{String}` — list of band names (e.g. `["B4","B3","B2"]`)
    - `:palette::Vector{String}` — color palette (e.g. `["red","green","blue"]`)
    - `:gain::Real` — gain factor
    - `:bias::Real` — bias offset
    - `:gamma::Real` — gamma correction

# Returns
A `Layer` instance with:
- `data` set to the provided source
- all other keyword arguments stored in the corresponding fields

# Examples
```julia
# A tile layer from OSM:
layer1 = layer(
  "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png";
  attribution="<a href=\"https://openstreetmap.org\">OSM</a>",
  maxZoom=19
)

# A GeoJSON layer with dynamic per-feature coloring:
layer2 = layer(
  geotable;
  multicolor=true,
  weight=1,
  fillOpacity=0.6
)

# An Earth Engine layer:
layer3 = layer(
  ee_image;
  min=0, max=3000,
  bands=["B4","B3","B2"],
  palette=["red","green","blue"]
)
```  
"""
function layer(data::Union{AbstractGeoTable,PyObject,String}; kwargs...)
  data_str = if data isa AbstractGeoTable
    geotable_to_geojson(data)
  elseif data isa PyObject
    eeobject_to_url(data; kwargs...)
  else
    # Check if it is a valid tile URL.
    is_valid_tile_url(data) ? data : error("invalid tile URL: ", data)
  end

  return Layer(; data=data_str, kwargs...)
end

"""
Helper function that converts a Layer into a descriptor dictionary.
For GeoJSON layers (where the `data` field starts with "{"),
parses the string using JSON3.read so that it is stored as a native object.
"""
function _layer_dict(layer::Layer)
  opts = Dict{Symbol,Any}()
  for f in fieldnames(typeof(layer))
    if f in (:data, :name, :shown, :opacity)
      continue
    end
    v = getfield(layer, f)
    v !== nothing && (opts[f] = v)
  end
  return Dict(
    :data => startswith(strip(layer.data), "{") ? JSON3.read(layer.data) : layer.data,
    :type => startswith(strip(layer.data), "{") ? "GeoJSON" : "Tile Url",
    :name => layer.name,
    :shown => layer.shown,
    :opacity => layer.opacity,
    :options => opts
  )
end

import Base.show

function show(io::IO, layer::Layer)
  println(io, "Layer Parameters:")
  for (k, v) in _layer_dict(layer)
    if k == :data
      continue  # Do not display the full data
    else
      println(io, string(k), ": ", repr(v))
    end
  end
end

# GeoMap structure change: the layers field is now a native vector (not a string).
@with_kw struct GeoMap
  lat::Real = -14.235004
  lon::Real = -51.92528
  zoom::Real = 4
  # The layers field is now an NTuple of dictionaries (each Dict has keys of type Symbol and values of Any)
  layers::NTuple{N,Dict{Symbol,Any}} where N = ()
end

function show(io::IO, gm::GeoMap)
  println(io, "GeoMap:")
  println(io, "  lat: ", gm.lat)
  println(io, "  lon: ", gm.lon)
  println(io, "  zoom: ", gm.zoom)
  if !isempty(gm.layers)
    println(io, "  Layers:")
    for (i, layer) in enumerate(gm.layers)
      println(io, "    Layer ", i, ":")
      for key in [:type, :name, :shown, :opacity, :options]
        if haskey(layer, key)
          if key == :options
            printed_opt = JSON3.write(layer[key]; indent=nothing)
            println(io, "      ", key, ": ", printed_opt)
          else
            println(io, "      ", key, ": ", layer[key])
          end
        end
      end
    end
  else
    println(io, "  (No layer descriptors)")
  end
end

"""
    geomap(layers...; lat, lon, zoom)

Construct a `GeoMap` from one or more `Layer` instances provided positionally,
with optional keyword overrides for `lat`, `lon`, and `zoom`.

- Positional args (`layers...`): any number of `Layer{T}` values.
- Keyword args:
  - `lat::Real`, `lon::Real`: Map center coordinates (defaults to Brazil’s centroid).
  - `zoom::Real`: Zoom level (default is 4).
  
The provided layers are processed through `_layer_dict` and then serialized
to a JSON string that is stored in the `layers` field.
"""
function geomap(layers::Layer...; lat::Real=-14.235004, lon::Real=-51.92528, zoom::Real=4)
  # Create an array of descriptors using _layer_dict.
  init_layers = _layer_dict.(layers)
  return GeoMap(lat=lat, lon=lon, zoom=zoom, layers=init_layers)
end

const assets = Asset.([
  "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",
  "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css",
  "https://cdnjs.cloudflare.com/ajax/libs/leaflet.draw/1.0.4/leaflet.draw.css",
  "https://cdnjs.cloudflare.com/ajax/libs/leaflet.draw/1.0.4/leaflet.draw.js",
  "https://cdn.jsdelivr.net/npm/@turf/turf@6/turf.min.js",
  "https://cdnjs.cloudflare.com/ajax/libs/chroma-js/1.3.3/chroma.min.js"
])

################################################################################
# Bonito Map Rendering Function
################################################################################
function Bonito.jsrender(session::Session, gm::GeoMap)
  js_code = js"""
    // Initialize the Leaflet map with the given center and zoom level.
    const map = L.map("map").setView([$(gm.lat), $(gm.lon)], $(gm.zoom));
    L.control.scale().addTo(map);

    function onEachFeature(feature, layer) {
      layer.on({
        mouseover: function(e) {
          if (feature.properties && feature.properties.name) {
            layer.bindTooltip(feature.properties.name).openTooltip();
          }
        },
        mouseout: function(e) {
          layer.closeTooltip();
        },
        click: function(e) {
          const areaSqMeters = turf.area(feature);
          const areaHa = (areaSqMeters / 10000).toFixed(2);
          layer.bindPopup("Area: " + areaHa + " ha").openPopup();
          map.fitBounds(layer.getBounds());
        }
      });
    }

    const carto = L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png", {
      maxZoom: 20, attribution: '&copy; OSM &copy; CARTO'
    });
    const osm = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 20, attribution: '&copy; OpenStreetMap contributors'
    });
    const googleSat = L.tileLayer("https://{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}", {
      maxZoom: 20, subdomains: ["mt0", "mt1", "mt2", "mt3"], attribution: '&copy; Google'
    });
    const esriImg = L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", {
      maxZoom: 20, attribution: '&copy; Esri'
    });
    carto.addTo(map);

    const baseLayers = { "Carto": carto, "OSM": osm, "Google Satellite": googleSat, "Esri Imagery": esriImg };
    let customOverlays = {};
    let layerControl = L.control.layers(baseLayers, customOverlays, {
      collapsed: true, position: "topright"
    }).addTo(map);

    map.on("baselayerchange", () => {
      [osm, googleSat, esriImg].forEach(l => l.bringToBack());
      Object.values(customOverlays).forEach(l => l.bringToFront());
    });

    const drawnItems = new L.FeatureGroup();
    map.addLayer(drawnItems);
    const drawControl = new L.Control.Draw({
      edit: { featureGroup: drawnItems },
      draw: { polygon: true, polyline: true, rectangle: true, marker: true, circle: false, circlemarker: false }
    });
    map.addControl(drawControl);

    map.on(L.Draw.Event.CREATED, e => {
      const layer = e.layer;
      drawnItems.addLayer(layer);
      onEachFeature(layer.toGeoJSON(), layer);
      Blink.msg("send_drawn", JSON.stringify(drawnItems.toGeoJSON()));
    });

    window.addOverlay = function(layerData, name, shown, options) {
      if (!name) {
        name = "Layer " + (Object.keys(customOverlays).length + 1);
      }
      let overlay;
      if (typeof layerData === "object" && layerData.type === "FeatureCollection") {
        if (options.multicolor === true) {
          const totalFeatures = layerData.features.length;
          layerData.features.forEach(function(feature, idx) {
            feature.properties._colorIndex = totalFeatures > 1 ? idx / (totalFeatures - 1) : 0;
          });
          options.style = function(feature) {
            const normVal = feature.properties._colorIndex;
            return {
              color: options.border_color || "#000",
              weight: options.border_width || 2,
              fillOpacity: options.fill_opacity || 0.5,
              fillColor: chroma.scale("YlGnBu")(normVal).hex()
            };
          };
          options.pointToLayer = function(feature, latlng) {
            return L.circleMarker(latlng, options.style(feature));
          };
          options.onEachFeature = onEachFeature;
        } else {
          options.onEachFeature = onEachFeature;
        }
        overlay = L.geoJSON(layerData, options);
      } else {
        overlay = L.tileLayer(layerData, options);
      }
      customOverlays[name] = overlay;
      if (shown !== false) {
        overlay.addTo(map);
        overlay.bringToFront();
      }
      layerControl.remove();
      layerControl = L.control.layers(baseLayers, customOverlays, {
        collapsed: true, position: "topright"
      }).addTo(map);
    };

    // Since gm.layers is already a native array of descriptors, simply iterate over it.
    const initial = JSON.parse($(JSON3.write(gm.layers)));
    initial.forEach(l => {
      window.addOverlay(l.data, l.name, l.shown, l.options);
    });

    window.theMap = map;
    window.layerControl = layerControl;
    window.baseLayers = baseLayers;
    window.overlays = customOverlays;
    window.drawnItems = drawnItems;
  """
  # Create the container in which Leaflet will render the map.
  map_div = DOM.div(id="map", style="height:500px; width:100%; position:relative;")
  # Combine the assets, the container and the JS code into one root structure.
  root = DOM.div(assets..., map_div, js_code)
  return Bonito.jsrender(session, root)
end

"""
    geoplot(gm::GeoMap)

Launches a Bonito application to render the given GeoMap.
This function wraps the provided GeoMap instance in an application container
with the title "geoplot" and displays it.
"""
function geoplot(gm::GeoMap)
  App(title="GeoMap") do
    gm
  end
end

function _ensure_geomap(map::App)
  if map.title != "GeoMap"
    throw(ArgumentError("The provided App must be of type GeoMap. Please create the App using the GeoMap constructor."))
  elseif map.session.x.status != Bonito.SessionStatus(3)
    throw(ArgumentError("The provided App's session is not open. Please ensure the app is running by re-running geoplot (e.g., app = geoplot(my_geo_map)) or reassign the variable. If the GeoMap is displayed in a VSCode window, keep that window open for interactive functionality."))
  end
end

function add_layer(gm::App, layer::Layer)
  # Verify that the App is indeed a GeoMap and if it is Open
  _ensure_geomap(gm)
  init_layer = _layer_dict(layer)
  js_call = js"""window.addOverlay($(init_layer[:data]), $(init_layer[:name]), $(init_layer[:shown]), $(init_layer[:options]));"""
  Bonito.evaljs(gm.session.x, js_call)
end

function get_features(gm::App)
  # Verify that the App is indeed a GeoMap
  _ensure_geomap(gm)
  features = Bonito.evaljs_value(gm.session.x, js"""JSON.stringify(window.drawnItems.toGeoJSON());""") |> GeoJSON.read
  return length(features) == 0 ? "No Features Found" : GeoIO.asgeotable(features)
end

"""
    add_drawn_layer(app::App)

Directly retrieves the drawn features from the client-side map (via
`window.drawnItems.toGeoJSON()`), and adds them as a new overlay using
`window.addOverlay`. The overlay is named "Drawn Features" and is displayed
immediately.
"""
function add_drawn_layer(app::App; kwargs...)
  # First, ensure that the app is a valid GeoMap and its session is open.
  _ensure_geomap(app)
  init_layer = Layer(; data="", kwargs...) |> _layer_dict
  js_code = js"""
    const drawnFeatures = window.drawnItems.toGeoJSON();
    window.addOverlay(drawnFeatures, $(init_layer[:name]), $(init_layer[:shown]), $(init_layer[:options]));
  """
  # Evaluate the JS snippet within the app's session.
  Bonito.evaljs(app.session.x, js_code)

end

"""
    geotable_to_ee(geotable; kwargs...) -> ee.Feature or ee.FeatureCollection

Converts a GeoTable or SubGeoTable into an Earth Engine object.
This function reprojects the data to `LatLon{WGS84Latest}` if needed, writes the GeoTable as a GeoJSON string,
parses it, and returns either an ee.Feature (if the table contains one row) or an ee.FeatureCollection (if more than one row).
Additional keyword arguments are passed to `GeoJSON.write`.
"""
function geotable_to_ee(geotable::AbstractGeoTable)
  # Write the GeoTable to an IOBuffer using GeoJSON.write.
  io = IOBuffer()
  GeoJSON.write(io, geotable)
  json_text = String(take!(io))
  json_obj = JSON3.read(json_text)
  # Determine whether to return a Feature or FeatureCollection.
  if nrow(geotable) == 1
    # If it's a FeatureCollection with one feature, extract that feature.
    return ee.Feature(json_obj[:features][1])
  else
    return ee.FeatureCollection(json_obj)
  end
end