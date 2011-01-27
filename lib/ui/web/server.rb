require 'sinatra/base'
require "rack/csrf"
require 'rack-flash'
require 'erb'
require 'yaml'
require 'ap'


module Arachni
module UI

require Arachni::Options.instance.dir['lib'] + 'ui/cli/output'
require Arachni::Options.instance.dir['lib'] + 'framework'
require Arachni::Options.instance.dir['lib'] + 'rpc/xml/client/dispatcher'
require Arachni::Options.instance.dir['lib'] + 'rpc/xml/client/instance'

module Web

class Server < Sinatra::Base

    class OutputStream

        def initialize( output )
            @output  = output
        end

        def each
            yield "<pre>"
            @output << { '' => '<meta http-equiv="refresh" content="1">' }
            @output.each {
                |out|
                next if out.values[0].empty?
                yield "#{out.keys[0]}: #{out.values[0]}</br>"
            }
        end

    end

    use Rack::Flash

    configure do
        use Rack::Session::Cookie
        use Rack::Csrf, :raise => true
    end

    helpers do

        def selected_tab?( tab )
            splits = env['PATH_INFO'].split( '/' )
            ( splits.empty? && tab == '/' ) || splits[1] == tab
        end

        def csrf_token
            Rack::Csrf.csrf_token( env )
        end

        def csrf_tag
            Rack::Csrf.csrf_tag( env )
        end

        def helper_instance
            @@arachni ||= nil
            if !@@arachni
                instance = dispatcher.dispatch( 'Web Interface [Do *not* kill]' )
                @@arachni = connect_to_instance( instance['port'] )
            end
            return @@arachni
        end

        def modules
            @@modules ||= helper_instance.framework.lsmod.dup
        end

        def plugins
            @@plugins ||= helper_instance.framework.lsplug.dup
        end

        def proc_mem( rss )
            # we assume a page size of 4096
            (rss.to_i * 4096 / 1024 / 1024).to_s + 'MB'
        end

        def secs_to_hms( secs )
            secs = secs.to_i
            return [secs/3600, secs/60 % 60, secs % 60].map {
                |t|
                t.to_s.rjust( 2, '0' )
            }.join(':')
        end

    end

    dir = File.dirname( File.expand_path( __FILE__ ) )

    set :views,  "#{dir}/server/views"
    set :public, "#{dir}/server/public"
    set :static, true
    set :environment, :development

    set :dispatcher_url, 'http://localhost:7331'

    enable :sessions

    def exception_jail( &block )
        # begin
            block.call
        # rescue Exception => e
        #     erb :error, { :layout => false }, :error => e.to_s
        # end
    end

    def show( page, layout = true )
        exception_jail {
            if page == :dispatcher
                erb :dispatcher, { :layout => true }, :stats => dispatcher.stats
            else
                erb page.to_sym,  { :layout => layout }
            end
        }
    end

    def connect_to_instance( port )
        uri = URI( settings.dispatcher_url )
        uri.port = port.to_i
        begin
            return Arachni::RPC::XML::Client::Instance.new( options, uri.to_s )
        rescue Exception
            raise "Instance on port #{port} has shutdown."
        end
    end

    def dispatcher
        @dispatcher ||= Arachni::RPC::XML::Client::Dispatcher.new( options, settings.dispatcher_url )
    end

    def options
        Arachni::Options.instance
    end

    def prep_opts( params )
        cparams = {}
        params.each_pair {
            |name, value|

            next if name == '_csrf' || ( value.is_a?( String ) && value.empty?)

            value = true if value == 'on'
            cparams[name] = value
        }

        if !cparams['audit_links'] && !cparams['audit_forms'] &&
              !cparams['audit_cookies'] && !cparams['audit_headers']

            cparams['audit_links']   = true
            cparams['audit_forms']   = true
            cparams['audit_cookies'] = true
        end

        return cparams
    end

    def prep_modules( params )
        mods = params['modules'].keys
        return ['*'] if mods.empty?
        return mods
    end

    def prep_plugins( params )
        plugins  = {}

        return plugins if !params['plugins']
        params['plugins'].keys.each {
            |name|
            plugins[name] = {}
        }
        return plugins
    end

    def prep_session
        session['opts'] ||= {
            'audit_links'    => true,
            'audit_forms'    => true,
            'audit_cookies'  => true,
            'http_req_limit' => 20,
            'user_agent'     => 'Arachni/' + Arachni::VERSION
        }
        session['opts']['modules'] ||= [ '*' ]
        session['opts']['plugins'] ||= {
            'content_types' => {},
            'healthmap'     => {}
        }
    end

    get "/" do
        prep_session
        show :home
    end

    get "/dispatcher" do
        show :dispatcher
    end

    post "/scan" do

        if !params['url'] || params['url'].empty?
            flash[:err] = "URL cannot be empty."
            show :home

        else

            instance = dispatcher.dispatch( params['url'] )
            arachni  = connect_to_instance( instance['port'] )

            session['opts']['url'] = params['url']

            session['opts']['audit_links']   = true if session['opts']['audit_links']
            session['opts']['audit_forms']   = true if session['opts']['audit_forms']
            session['opts']['audit_cookies'] = true if session['opts']['audit_cookies']
            session['opts']['audit_headers'] = true if session['opts']['audit_headers']

            arachni.opts.set( session['opts'] )
            arachni.modules.load( session['opts']['modules'] )
            arachni.plugins.load( session['opts']['plugins'] )
            arachni.framework.run

            redirect '/instance/' + instance['port'].to_s
        end

    end

    get "/modules" do
        prep_session
        show :modules, true
    end

    post "/modules" do
        session['opts']['modules'] = prep_modules( params )
        flash.now[:notice] = "Modules updated."
        show :modules, true
    end

    get "/plugins" do
        prep_session
        erb :plugins, { :layout => true }
    end

    post "/plugins" do
        session['opts']['plugins'] = prep_plugins( params )
        flash.now[:notice] = "Plugins updated."
        show :plugins, true
    end

    get "/settings" do
        prep_session
        erb :settings, { :layout => true }
    end

    post "/settings" do
        session['opts'].merge!( prep_opts( params ) )
        flash.now[:notice] = "Settings updated."
        show :settings, true
    end

    get "/instance/:port" do
        show :instance, true
    end

    get "/instance/:port/output" do
        exception_jail {
            arachni = connect_to_instance( params[:port] )

            if arachni.framework.busy?
                OutputStream.new( arachni.service.output )
            else
                report = YAML::load( arachni.framework.report )
                arachni.service.shutdown!
                "<pre>" + report.to_s + "</pre>"
            end
        }
    end

    post "/*/:port/pause" do
        ap env
        exception_jail {
            connect_to_instance( params[:port] ).framework.pause!
            flash.now[:notice] = "Instance on port #{params[:port]} will pause as soon as the current page is audited."
            show params[:splat][0].to_sym
        }
    end

    post "/*/:port/resume" do
        exception_jail {
            connect_to_instance( params[:port] ).framework.resume!
            flash.now[:ok] = "Instance on port #{params[:port]} resumes."
            show params[:splat][0].to_sym
        }
    end

    post "/*/:port/shutdown" do
        exception_jail {
            connect_to_instance( params[:port] ).service.shutdown!
            flash.now[:ok] = "Instance on port #{params[:port]} has been shutdown."
            show params[:splat][0].to_sym
        }
    end

    get "/stats" do
        dispatcher.stats.to_s
    end

    run!
end

end
end
end
