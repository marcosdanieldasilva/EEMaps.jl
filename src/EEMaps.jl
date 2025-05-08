module EEMaps

using PyCall

const ee = PyNULL()

version() = VersionNumber(ee.__version__)

"""
    initialize(project::String)

Initializes an Earth Engine session using the specified GCP project ID.
If the session cannot be initialized (e.g. no valid credentials), it will attempt
to authenticate and then re-initialize.

Example:
    initialize("your-gcp-project-id")
"""
function initialize(project_id::String)
  try
    copy!(ee, pyimport("ee"))
  catch err
    error(
      "The `earthengine-api` package could not be imported. You must install the Python earthengine-api before using this package. The error was $err",
    )
  end

  try
    ee.Initialize(project=project_id)

  catch
    @warn "Could not initialize an `ee` session. Trying authentication workflow..."

    try
      authenticate()
      ee.Initialize(project=project_id)
    catch
      error(
        "Could not initialize an `ee` session or run authentication workflow. Please authenticate manually using the earthengine-api CLI (i.e. `\$ earthengine authenticate`",
      )
    end
  end

end

"""
    Authenticate()

Function to execute the EarthEngine authetication workflow (analgous to
ee.Authenticate() in the Python API). This function should only be executed
once if the EE API has not be used before.
"""
function authenticate(args...; kwargs...)
  try
    ee.Authenticate(args...; kwargs...)
  catch err
    @error "Could not authenticate `ee`...see following error: $err"
  end
end

export ee, initialize, authenticate

end
