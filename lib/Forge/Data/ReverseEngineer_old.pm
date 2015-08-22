#!/usr/bin/env perl

package Data::ReverseEngineer;

use Cwd qw[abs_path];
use File::Spec::Functions qw[catfile];

use Rose::DB;
use Rose::DB::Object;
use Rose::DB::Object::Loader;
use Data::Dumper;

use Util::Lang;

# For dying gracefully
use Carp;

# Before pre-compile time
BEGIN {
	# Make accessors and mutators
	Util::Lang->make_accessors( __PACKAGE__, "namespace", "base_package", "output_dir", "db" );
}

#
# Prefix comment for newly generated files
#
sub COMMENT { # $ ()
	my $now = localtime();
	<<COM
#!/usr/bin/env perl

#
# Auto-generated by Forge::Data::ReverseEngineer at $now
# 

COM
;
}

sub R_BASE_TEMPLATE { # $ ($)
	my ($namespace, $type) = @_;
	<<R
#!/usr/bin/env perl

package $namespace;

use Forge::DBC;
use base qw(Rose::DB::Object);

sub init_db {
	Forge::DBC->new_or_cached( type => '$namespace' );
}

R
;
}

sub R_PACKAGE { 'Forge::Model::R' };

#
# (hash) -> Data::ReverseEngineer
# 
# Creates new instance of ReverseEngineer
# 
# Requires parameter:
#  - database
#  
# Optional parameters are:/
#  - output_dir
#  - base_package
#
sub new { # $ (%)
	my $class = shift;
	$class = ref($class) || $class;
	# Parameters of connection
	my %params = @_;

	my $database = $params{ database };
	unless( $database ) {
		Carp::croak( "Forge::Data::ReverseEngineer requires [database] parameter to create an instance" );
	}

	# Bless object with reference to this package
	# And do unholy things with it
	my $inst = bless {}, $class;
	# Set reference to Rose::DB
	$inst->db( $database );
	# Set package namespace
	# Package namespace is defined in base module for given database
	$inst->namespace($params{namespace});
	# Output directory: given or default
	$inst->output_dir( $params{output} || "./lib/Forge/Model/R" );
	# Return blessed instance
	$inst;
}

sub make_base {
	my ($inst, $ns) = @_;
	$ns = ucfirst lc $ns;
	print "namespace: $ns \n";
	my $fh;
	my $filepath = catfile( abs_path($inst->output_dir), $ns . 'Base.pm' );
	print "filepath: $filepath\n";
	my $r_package = R_PACKAGE . "::$ns" . "Base";
	my $base_module = R_BASE_TEMPLATE( $r_package, $ns );
	TRY: {
		local $@;
		eval { 
			open $fh, '+>:encoding(utf-8)', $inst->output_dir . '';
			print "content: $base_module\n";
			print $fh $base_module;
			close $fh;
		};

		if ($@) {
			return Carp::croak( "Unable to write contents to file [$filepath]: $@" );
		}
	}

	$r_package;
}

#
# () -> Rose::DB::Object::Loader
# 
# Returns a new instance of Rose::DB::Object::Loader
# with given configurations of ReverseEngineer
#
sub create_loader { # \$ ($)
	my ($inst, $class) = @_;
	Rose::DB::Object::Loader->new(
		base_class => $class,
		module_dir => $inst->output_dir,
		
		# Database connection instance
		db => $inst->db,
		
		force_lowercase => 1,
		with_managers => 0,
	);
}

#
# () -> boolean !
# 
# Loads database schema as Rose::DB::Objects to represent db
# structure in perl scripts.
# 
# Returns boolean if loading and processing was successful
#
sub process { # $ ()
	my ($inst) = @_;
	
	my $base_package = $inst->make_base( $inst->db->type );
	$inst->base_package( $base_package );

	# Rose DB loader
	my $loader = $inst->create_loader;
	# Load schema
	# This generates files in output directory and returns a list of generated modules
	my $modules = $loader->make_modules; # !
	# Check if modules were generated
	unless ($modules) {
		return 0;
	}

	# Now we post process generated modules
	$inst->post_process( $modules );
}

#
# (Rose::DB::Object::Loader) -> !
# 
#
sub generate_loader { # void ($)

}

#
# (array) -> boolean !
#
sub post_process { # $ (@)
	my ($inst, $modules) = @_;

	# First open module directory
	my ( $dh, $package_file );
	opendir $dh, $inst->output_dir 
		or Carp::croak( "Unable to open dir [" . $inst->output_dir . "]. Cause: $!" );

	while ($package_file = readdir $dh) {
		# Skip if we're dealing with anything but perl module
		next unless $inst->is_module( $package_file );
		# Cache package file path
		my $class_path = $inst->class_path( $package_file );
		# Open file for reading
		open( my $input, '<', $class_path ) 
			or Carp::croak( "Unable to open [$class_path] for reading: $!" );
		# Make changes to script
		my $new_script = $inst->modify_script( $package_file, $input );
		# Close input stream and release resources associated with it
		close $input;
		# Write new script back to same file
		$inst->write_changes( $class_path, $new_script );
	}

	# Close dir handler
	close $dh;	
	
	1;
}

#
# (string, FileHandler) -> ref Array
#
# Modifies content of generated Rose::DB::Object perl module
# to accomodate for project needs.
# 
# Specifically - adds manager and connects it to a valid DB DSN connection
#
sub modify_script { # \@ ($, $)
	my ($inst, $package_file, $input) = @_;
	# Store package name for mutability
	my $package = $package_file;
	# Lines of output to write later.
	my @output = ();
	
	# Remove extension from package file
	$package =~ s/\.pm$//g;
	# Transform to under_score case to represent table name alias
	$package =~ s/([^A-Z-])([A-Z])/$1_$2/g;
	# And finally lowercase it
	$package = lc $package;
	# Prepend informational comment
	push @output, COMMENT;
	# Iterate through lines and push them back to @output making necessary changes in the process
	while (<$input>) {
		# Push everything back to output until we meet the end of module script
		unless ( /^1;(\s+)?/ ) {
			push @output, $_;
			next;
		}
		# Once we met the end of module script everything after it is irrelevant and may be discarded
		last;
	}
	# Append manager initializer to module script
	push @output, "__PACKAGE__->meta->make_manager_class('$package');\n\n";
	# Append end of script marker
	push @output, "1;";
	# Rreturn modified script as array reference
	\@output;
}

#
# (string, array ref) -> !
#
sub write_changes { # void ($, \@)
	my ($inst, $path, $script) = @_;
	# Open file back
	open my $out, '+>', $path 
		or Carp::croak "Unable to open file [$path] for writing. Cause: $!";
	
	print $out join '', @{ $script };
	close $out;
}

#
# (string) -> String
# 
# Returns package/class file path of given module
# Appends output directory of generated module
#
sub class_path { # $ ($)
	shift->output_dir . "/" . shift;
}

#
# (string) -> Boolean
# 
# Runs a simple check that given file is a perl module
# in class_path of given file.
#
sub is_module { # $ ($)
	$_[1] =~ /\.pm/gi and -f $_[0]->class_path( $_[1] );
}

1;