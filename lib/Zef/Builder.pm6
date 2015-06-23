use Zef::Utils::Depends;
use Zef::Utils::PathTools;


# We cannot use this CompUnit until we figure out how to make it work with 
# MONKEY-TYPING modules that are currently loaded. In our case, Zef::Utils::PathTools 
# will return a CompUnit and not the Zef::CompUnit
class Zef::CompUnit is CompUnit {
    has $!path;
    has $!has-precomp;
    has $.precomp-path;
    has $.build-output is rw;

    method precomp($out, |c) {
        $!precomp-path = $out //= self.precomp-path // "{$!path}.{$*VM.precomp-ext}";
        mkdirs(self.precomp-path.IO.dirname);

        nextwith($!precomp-path, |c);
    }
}


# Provide functionality for precompiling modules
class Zef::Builder {
    # todo: lots of cleanup/refactoring
    method pre-compile(*@repos is copy, :$save-to is copy) {
        my @results = eager gather for @repos -> $path {
            my $SPEC := $*SPEC;
            my %meta  = %(from-json( $SPEC.catpath('', $path, 'META.info').IO.slurp) );

            # NOTE: this may change
            # Currently treats relative paths as relative to the current repo's path ($path).
            # It may or may not be better to treat them as relative to the users CWD. We shall see.
            temp $save-to = $save-to 
                ?? ($save-to.IO.is-absolute ?? $save-to.IO !! $SPEC.catdir($save-to, $path).IO) 
                !! $path.IO;
            say "===> Build directory: {$save-to.absolute}";

            # Determine the paths where the sources are located, where the pre-compiled 
            # code should go, and what $INC should include before pre-compiling.
            my @libs     = %meta<provides>.list.map({
                $*SPEC.rel2abs($SPEC.splitdir($_.value.IO.dirname).[0].IO // $SPEC.curdir, $path)
            }).unique.map({ CompUnitRepo::Local::File.new($_).Str });
            state @blibs.push($_) for @libs.map({ 
                CompUnitRepo::Local::File.new( $SPEC.rel2abs($SPEC.catdir('blib', $SPEC.abs2rel($_, $path)), $save-to) ).Str;
            });
            my $INC     := @blibs.unique, @libs, @*INC;
            my @files    = %meta<provides>.list.map({ $SPEC.rel2abs($_.value, $path).IO.path });

            # Build the @dep chain for the %META.<provides> by parsing the 
            # use/require/need from the module source.
            my @provides-as-deps = gather for @(extract-deps( @files ).list) -> $info is rw {
                my @provided-ok = eager gather for $info.<depends>.list -> $dep {
                    unless %meta.<provides>.{$dep}:exists {
                        say "!!!> Confused. META `provides` has no mapping for: $dep";
                        next;
                    }
                    take $dep;
                }

                $info.<depends> = [@provided-ok.map({ %meta.<provides>.{$_} })];
                $info.<name>    = %meta.<provides>.list.first({ $info.<path>.ends-with($_.value) }).value;
                take $info;
            }

            # @provides-as-deps is a partial META.info hash, so pass the $meta.<provides>
            # Note topological-sort with no arguments will sort the class's @projects (provides in this case)
            my @levels   = Zef::Utils::Depends.new(projects => @provides-as-deps).topological-sort;

            # Create the build order for the `provides`
            my @compiled = eager gather for @levels -> $level {
                for $level.list -> $module-id {
                    # Workaround for non-default precomp-path 
                    # i.e. $out = /blib/lib/Name.pm6.ext instead of /lib/Name.pm6.ext
                    # CompUnit was not designed to be subclassed, so this is kinda ugly.
                    my $cu := CompUnit.new( $SPEC.rel2abs($module-id, $path) ) but role { 
                        has $!has-precomp = False;
                        has $.build-output is rw;
                        has $.precomp-path is rw;

                        method BUILDALL(|) {
                            my $return = callsame;
                            $!precomp-path := pp();
                            return $return;
                        }

                        method precomp($out, |c) { 
                            mkdirs($out.IO.dirname);
                            $!precomp-path = $out;
                            $!has-precomp  = callwith($out, |c);
                        }

                        sub pp() is rw {
                            my $storage;
                            Proxy.new: FETCH => method ()   { $storage.IO.absolute if ?$storage },
                                       STORE => method ($p) { $storage = $p };
                        }
                    }
                    

                    # Relative and absolute file paths of where to *save* compiled ouput.
                    my $new-id-rel      := $SPEC.catpath(
                        '', $SPEC.catdir('blib', $module-id.IO.dirname),  # add blib/ path prefix
                        "{$module-id.IO.basename}.{$*VM.precomp-ext}"     # add precomp-extension
                    ).IO;
                    # relative to '$save-to', not relative to the repo source ($path)
                    my $new-id-absolute := $SPEC.rel2abs($new-id-rel, $save-to).IO;

                    # todo: .build-output should really be a Channel/Supply to let the client
                    # tap/receieve the output instead of just printing it (like Zef::Test)
                    $cu.build-output  = "[{$module-id}] {'.' x 42 - $new-id-rel.chars} ";
                    $cu.build-output ~= do given $cu.precomp($new-id-absolute, :$INC, :force) {
                        when *.so  { "ok: {$SPEC.abs2rel($cu.precomp-path, $save-to)}\n" }
                        when *.not { "FAILED\n"                                          }
                    }

                    print $cu.build-output;

                    take $cu;
                }
            }

            # subclassing CompUnit seems to get screw when calling .new on a module 
            # that augments core functionality (Utils::PathTools and augment IO::Path?)
            # so we will use this structure for now instead of a custom CompUnit extension
            take {  
                ok           => ?(@compiled.grep({ ?$_.has-precomp }).elems == %meta<provides>.list.elems),
                precomp-path => @blibs[0], 
                path         => $path, 
                curlfs       => @compiled, 
                sources      => %meta<provides>.list,
                module       => %meta<name>,
            }
        }

        return @results;
    }
}
