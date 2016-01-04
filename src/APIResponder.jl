type APISpec
    fn::Function
    resp_json::Bool
    resp_headers::Dict
end

type APIResponder
    ctx::Context
    sock::Socket
    endpoints::Dict{AbstractString, APISpec}
    nid::AbstractString

    function APIResponder(addr::AbstractString, ctx::Context=Context(), bind::Bool=true, nid::AbstractString="")
        a = new()
        a.ctx = ctx
        a.nid = nid
        a.sock = Socket(ctx, REP)
        a.endpoints = Dict{AbstractString, APISpec}()
        if bind
            ZMQ.bind(a.sock, addr)
        else
            ZMQ.connect(a.sock, addr)
        end
        a
    end
    APIResponder(ip::IPv4, port::Int, ctx::Context=Context()) = APIResponder("tcp://$ip:$port", ctx)
end

function Base.show(io::IO, x::APIResponder)
    println(io, "JuliaWebAPI.APIResponder with endpoints:")
    Base.show_comma_array(STDOUT, keys(x.endpoints), "","")
end

# register a function as API call
# TODO: validate method belongs to module?
function register(conn::APIResponder, f::Function;
                  resp_json::Bool=false,
                  resp_headers::Dict=Dict{AbstractString,AbstractString}())
    endpt = string(f)
    Logging.debug("registering endpoint [$endpt]")
    conn.endpoints[endpt] = APISpec(f, resp_json, resp_headers)
    return conn #make fluent api possible
end

function respond(conn::APIResponder, code::Int, headers::Dict, resp::Any)
    msg = Dict{AbstractString,Any}()

    isempty(conn.nid) || (msg["nid"] = conn.nid)

    if !isempty(headers)
        msg["hdrs"] = headers
        Logging.debug("sending headers [$headers]")
    end

    msg["code"] = code
    msg["data"] = resp

    msgstr = JSON.json(msg)
    Logging.debug("sending response [$msgstr]")
    ZMQ.send(conn.sock, Message(msgstr))
end

respond(conn::APIResponder, api::Nullable{APISpec}, status::Symbol, resp::Any=nothing) =
    respond(conn, ERR_CODES[status][1], get_hdrs(api), get_resp(api, status, resp))

function call_api(api::APISpec, conn::APIResponder, args::Array, data::Dict{Symbol,Any})
    try
        result = api.fn(args...; data...)
        respond(conn, Nullable(api), :success, result)
    catch ex
        Logging.error("api_exception: $ex")
        respond(conn, Nullable(api), :api_exception)
    end
end

function get_resp(api::Nullable{APISpec}, status::Symbol, resp::Any=nothing)
    st = ERR_CODES[status]
    stcode = st[2]
    stresp = ((stcode != 0) && (resp === nothing)) ? "$(st[3]) : $(st[2])" : resp

    if !isnull(api) && get(api).resp_json
        return @compat Dict{AbstractString, Any}("code" => stcode, "data" => stresp)
    else
        return stresp
    end
end

get_hdrs(api::Nullable{APISpec}) = !isnull(api) ? get(api).resp_headers : Dict{AbstractString,AbstractString}()

args(msg::Dict) = get(msg, "args", [])
data(msg::Dict) = convert(Dict{Symbol,Any}, get(msg, "vargs", Dict{Symbol,Any}()))

# start processing as a server
function process(conn::APIResponder)
    Logging.debug("processing...")
    while true
        msg = JSON.parse(bytestring(ZMQ.recv(conn.sock)))

        cmd = get(msg, "cmd", "")
        Logging.info("received request [$cmd]")

        if startswith(cmd, ':')    # is a control command
            ctrlcmd = symbol(cmd[2:end])
            if ctrlcmd === :terminate
                respond(conn, Nullable{APISpec}(), :terminate, "")
                break
            else
                err("invalid control command $cmd")
                continue
            end
        end

        if !haskey(conn.endpoints, cmd)
            respond(conn, Nullable{APISpec}(), :invalid_api)
            continue
        end

        try
            call_api(conn.endpoints[cmd], conn, args(msg), data(msg))
        catch e
            err("exception $e")
            respond(conn, Nullable(conn.endpoints[cmd]), :invalid_data)
        end
    end
    close(api.sock)
    close(api.ctx)
    Logging.info("stopped processing.")
end

function setup_logging(;log_level=INFO, nid::AbstractString=get(ENV,"JBAPI_CID",""))
    api_name = get(ENV,"JBAPI_NAME", "noname")
    logfile = "apisrvr_$(api_name)_$(nid).log"
    Logging.configure(level=log_level, filename=logfile)
end

function process(apispecs::Array, addr::AbstractString=get(ENV,"JBAPI_QUEUE",""); log_level=INFO, bind::Bool=false, nid::AbstractString=get(ENV,"JBAPI_CID",""))
    setup_logging()
    Logging.debug("queue is at $addr")
    api = create_responder(apispecs, addr, bind, nid)

    Logging.debug("processing...")
    process(api)

end

function process_async(apispecs::Array, addr::AbstractString=get(ENV,"JBAPI_QUEUE",""); log_level=INFO, bind::Bool=false, nid::AbstractString=get(ENV,"JBAPI_CID",""))
    setup_logging()
    Logging.debug("queue is at $addr")
    api = create_responder(apispecs, addr, bind, nid)

    Logging.debug("processing...")
    @async process(api)
    return api
end

function create_responder(apispecs::Array{Tuple, 1}, addr, bind, nid)
    api = APIResponder(addr, Context(), bind, nid)
    for spec in apispecs
      fn = spec[1]
      resp_json = (length(spec) > 1) ? spec[2] : false
      resp_headers = (length(spec) > 2) ? spec[3] : Dict{AbstractString,AbstractString}()
      register(api, fn, resp_json=resp_json, resp_headers=resp_headers)
    end
    return api
end

function create_responder(apispecs::Array{Function, 1}, addr, bind, nid)
  api = APIResponder(addr, Context(), bind, nid)
  for spec in apispecs
      fn = spec
      resp_json =  false
      resp_headers =  Dict{AbstractString,AbstractString}()
      register(api, fn, resp_json=resp_json, resp_headers=resp_headers)
  end
  return api
end



function process()
    setup_logging()

    Logging.info("Reading api server configuration from environment...")
    Logging.info("JBAPI_NAME=" * get(ENV,"JBAPI_NAME",""))
    Logging.info("JBAPI_QUEUE=" * get(ENV,"JBAPI_QUEUE",""))
    Logging.info("JBAPI_CMD=" * get(ENV,"JBAPI_CMD",""))
    Logging.info("JBAPI_CID=" * get(ENV,"JBAPI_CID",""))

    cmd = get(ENV,"JBAPI_CMD","")
    eval(parse(cmd))
end
