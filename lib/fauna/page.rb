module Fauna
  ##
  # Helper for handling pagination over sets.
  #
  # Given a client and a set, allows you to iterate as well as individually move page by page over a set.
  #
  # Pages lazily load the contents of the page. Loading will occur when +data+, +before+, or +after+ are first accessed
  # for a new page. Additionally this will occur when calling +page_before+ or +page_after+ without calling one of the
  # data methods first (as the first page must be checked to find the next page). Pages created by builders will unload
  # any data from the current page. Pages will always proceed in the requested direction.
  #
  # Explicit paging is done via the +page_after+ and +page_before+ methods. Iteration can be done via the +each+ and
  # +reverse_each+ enumerators. A single page can be retrieved by passing a cursor and then accessing it's data.
  #
  # Examples:
  #
  # Paging over a class index
  #
  #   page = Page.new(client, Query.match(Ref('indexes/items')))
  #
  # Paging over a class index 5 at a time, mapping the refs to the +data.value+ for each instance
  #
  #   page = Page.new(client, Query.match(Ref('indexes/items')), size: 5) do |page|
  #     map(page) { |ref| select ['data', 'value'], get(ref) }
  #   end
  #
  #   # Same thing, but using builders instead
  #
  #   page = Page.new(client, Query.match(Ref('indexes/items'))).with_params(size: 5).with_map do |page|
  #     map(page) { |ref| select ['data', 'value'], get(ref) }
  #   end
  class Page
    ##
    # Creates a pagination helper for paging/iterating over a set.
    #
    # +client+:: Client to execute queries with.
    # +set+:: A set query to paginate over.
    # +params+:: A list of parameters to pass to {paginate}[https://faunadb.com/documentation/queries#read_functions-paginate_set].
    # +fauna_map+:: Optional block to wrap the generated paginate query with. The block will be run in a query context.
    #               The paginate query will be passed into the block as an argument.
    def initialize(client, set, params = {}, &fauna_map)
      @client = client
      @set = set
      @params = params.dup
      @fauna_map = fauna_map
      @ruby_map = nil

      unload_page
      @params.freeze
    end

    # Returns +true+ if +other+ is a Page and contains the same configuration and data.
    def ==(other)
      return false unless other.is_a? Page
      @populated == other.instance_variable_get(:@populated) &&
        @data == other.instance_variable_get(:@data) &&
        @before == other.instance_variable_get(:@before) &&
        @after == other.instance_variable_get(:@after) &&
        @client == other.instance_variable_get(:@client) &&
        @set == other.instance_variable_get(:@set) &&
        @params == other.instance_variable_get(:@params) &&
        @fauna_map == other.instance_variable_get(:@fauna_map) &&
        @ruby_map == other.instance_variable_get(:@ruby_map)
    end

    alias_method :eql?, :==

    # The configured params used for the current pagination.
    attr_reader :params

    ##
    # Explicitly loads data for the current page if it has not already been loaded.
    #
    # Returns +true+ if the data was just loaded and +false+ if it was already loaded.
    def load!
      if @populated
        false
      else
        load_page(get_page(@params))
        true
      end
    end

    # :section: Data

    ##
    # Data contained within the current page.
    #
    # Lazily loads the page data if it has not already been loaded.
    def data
      load!
      @data
    end

    ##
    # Before cursor for the current page.
    #
    # Lazily loads the page data if it has not already been loaded.
    def before
      load!
      @before
    end

    ##
    # After cursor for the current page.
    #
    # Lazily loads the page data if it has not already been loaded.
    def after
      load!
      @after
    end

    # :section: Builders

    ##
    # Returns a copy of the page with the given +params+ set.
    #
    # See {paginate}[https://faunadb.com/documentation/queries#read_functions-paginate_set] for more details.
    def with_params(params = {})
      with_dup do |page|
        page_params = page.instance_variable_get(:@params)

        if CURSOR_KEYS.any? { |key| params.include? key }
          # Remove previous cursor
          CURSOR_KEYS.each { |key| page_params.delete key }
        end

        # Update params
        page_params.merge!(params)
      end
    end

    ##
    # Returns a copy of the page with the given fauna block set.
    #
    # The block, when provided, will be used to wrap the generated paginate query with a fauna query.
    # The block will be run in a Query.expr context, and passed the generated paginate query as a parameter.
    #
    # Example of mapping a set of refs to their instances:
    #
    #   page.with_map { |page_q| map(page_q) { |ref| get ref } }
    def with_map(&block)
      with_dup do |page|
        page.instance_variable_set(:@fauna_map, block)
      end
    end

    ##
    # Returns a copy of the page with the given ruby block set.
    #
    # The block, when provided, will be used to map the returned data elements from the executed fauna query.
    # The block will be passed the each element as a parameter from the data of the page currently being loaded.
    #
    # Intended for use when the elements in a page need to be converted within ruby (ie loading into a model). Wherever
    # the operation can be performed from within FaunaDB, +with_map+ should be used instead.
    #
    # Example of loading instances into your own model:
    #
    #   page.with_postprocessing_map { |instance| YourModel.load(instance) }
    def with_postprocessing_map(&block)
      with_dup do |page|
        page.instance_variable_set(:@ruby_map, block)
      end
    end

    # :section: Pagination

    ##
    # The page after the current one in the set.
    #
    # Returns +nil+ when there are no more pages after the current page. Lazily loads the current page if it has not
    # already been loaded in order to determine the page after.
    def page_after
      new_page(:after)
    end

    ##
    # The page before the current one in the set.
    #
    # Returns +nil+ when there are no more pages before the current page. Lazily loads the current page if it has not
    # already been loaded in order to determine the page before.
    def page_before
      new_page(:before)
    end

    ##
    # Returns an enumerator that iterates in the +after+ direction.
    #
    # When a block is provided, the return of the block will always be +nil+ (to avoid loading large sets into memory).
    def each
      return enum_for(:each) unless block_given?

      # Return current page
      yield data

      # Begin returning pages before
      page = self.page_after
      until page.nil?
        yield page.data
        page = page.page_after
      end
    end

    ##
    # Returns an enumerator that iterates in the +before+ direction.
    #
    # When a block is provided, the return of the block will always be +nil+ (to avoid loading large sets into memory).
    #
    # While the paging will occur in the reverse direction, the data returned will still be in the normal direction.
    def reverse_each
      return enum_for(:reverse_each) unless block_given?

      # Return current page
      yield data

      # Begin returning pages before
      page = self.page_before
      until page.nil?
        yield page.data
        page = page.page_before
      end
    end

    def dup # :nodoc:
      page = super
      page.instance_variable_set(:@params, @params.dup)
      page
    end

  private

    CURSOR_KEYS = [:before, :after] # :nodoc:

    def with_dup
      # Create a copy and drop loaded data
      page = self.dup
      page.send(:unload_page)

      # Yield page for manipulation
      yield page

      # Freeze params and return page
      page.params.freeze
      page
    end

    def get_page(params)
      # Create query
      query = Query.paginate @set, params

      unless @fauna_map.nil?
        # Wrap paginate query with the fauna block
        dsl = Query::QueryDSLContext.new
        query = Query::Expr.wrap DSLContext.eval_dsl(dsl, query, &@fauna_map)
      end

      # Execute query
      result = @client.query query

      unless @ruby_map.nil?
        # Map the resulting data with the ruby block
        result[:data].map! { |element| @ruby_map.call(element) }
      end

      # Return result
      result
    end

    def load_page(page)
      # Not initial after the first page
      @populated = true

      # Update the page fields
      @data = page[:data]
      @before = page[:before]
      @after = page[:after]
    end

    def unload_page
      # Reset paging
      @populated = false

      # Reset data
      @data = nil
      @before = nil
      @after = nil
    end

    def new_page(direction)
      fail "Invalid direction; must be one of #{CURSOR_KEYS}" unless CURSOR_KEYS.include?(direction)

      cursor = self.send(direction)

      # If there is no next cursor, we have reached the end of the set.
      # Return +nil+.
      return nil if cursor.nil?

      # Use the configured cursor to fetch the first page.
      with_params(direction => cursor)
    end
  end
end