==================
 Allmyles PHP SDK
==================

---------
 Summary
---------

The Allmyles PHP SDK is a PHP package aiming to simplify integration of the
`Allmyles API <http://allmyles.com>`_ into PHP projects. The SDK is designed to
be as forgiving as possible, often accepting multiple types as input, handling
conversion between different (at least somewhat sensible) types automatically.

You can find the project's source on
`GitHub <https://github.com/allmyles/allmyles-sdk-php>`_.

--------------
 Installation
--------------

Just add this in your composer.json file and run ``composer install``::

    "require": {"allmyles/allmyles-sdk-php": "1.*"}

Or, if for some reason you can't use a package manager, you can also just
download the SDK's source in a ZIP archive from
`GitHub <https://github.com/allmyles/allmyles-sdk-php>`_ and handle your
dependencies manually. You *really* shouldn't be doing that, though.

--------------
 Example Code
--------------

The allmyles-sdk-php repository contains several examples in
`/doc/examples/ <https://github.com/allmyles/allmyles-sdk-php/tree/master/doc/examples>`_.
You might want to try those to get a general feel for how the SDK and the
ticketing process work in general before you delve into the details down below.

There's code for three different ways to use the API---these are completely
intercompatible, though. We recommend you to read through the simple booking
flow first, as that contains everything you need to successfully create a
ticket. The complex flow is kind of a showcase for all the advanced ways you
can use the API, you will most likely not need everything from there. (It
might be a good idea to start reading the API Reference once you're about to
start experimenting with these advanced features.)

The raw examples take a lot of responsibility off the shoulders of the SDK; the
requests are written more or less manually in those. This should be used by
advanced users who don't feel comfortable deferring the task of crafting the
requests to the SDK, and would rather build arrays themselves instead of using
the SDK's query classes. Raw requests might also come in handy if the Allmyles
API has new features deployed that aren't supported by the SDK just yet.

----------------
 Initialization
----------------

Initialization is done by creating an :php:class:`Allmyles\\Client` object
with the API access details given as arguments. Each request will be made via a
method call to this object.

Initialization will look something like this:

.. sourcecode:: php

  $allmyles = new Allmyles\Client('https://api.allmyles.com/v2.0', 'api-key');

---------------
 API Reference
---------------

.. php:namespace:: Allmyles

.. php:class:: Client

  .. php:method:: __construct($baseUrl, $authKey)

      Initializes your Allmyles client.

      :param string $baseUrl: The URL of the Allmyles API you're using
                              (ex. ``https://api.allmyles.com/v2.0)``.
      :param string $authKey: Your API key for the Allmyles API.

      :returns: A :php:class:`Client` object.

  .. php:method:: searchFlight($parameters[, $async = true, $session = null])

      Sends a flight search request to the Allmyles API.

      :param mixed $parameters: This should be either a
          :php:class:`Flights\\SearchQuery` object, or an associative array
          containing the raw data to be sent off based on the
          :ref:`Flight_Search` API docs.
      :param boolean $async: Whether the SDK should defer asyncronosity to your
          code or not. Setting this to false will make the method call block
          until a search response arrives (which can take around 30-40
          seconds.) If it's true you will need to periodically call the
          response's retry method yourself until the results arrive.
      :param string $session: If you want to manually set the session cookie
          for the workflow, specify it here. The SDK automatically handles
          sessions, though, so feel free to leave this out.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an array of
        :php:class:`Flights\\FlightResult` objects.

  .. php:method:: searchHotel($parameters[, $session = null])

      Sends a hotel search request to the Allmyles API.

      :param mixed $parameters: This should be either a
          :php:class:`Hotels\\SearchQuery` object, or an associative array
          containing the raw data to be sent off based on the
          :ref:`Hotel_Search` API docs.
      :param string $session: If you want to manually set the session cookie
          for the workflow, specify it here. The SDK automatically handles
          sessions, though, so feel free to leave this out.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an array of
        :php:class:`Hotels\\Hotel` objects.

  .. php:method:: searchLocations($parameters[, $session = null])

      Sends a masterdata search request to the Allmyles API.

      :param array $parameters: This should be an associative array containing
          the raw data to be sent off based on the :ref:`Masterdata_Search`
          API docs.
      :param string $session:

      :returns: An associative array containing the location search results.

  .. php:method:: retrieveMasterdata($repo[, $session = null])

      Sends a masterdata retrieval request to the Allmyles API.

      :param string $repo: This should be the name of one of the data repos
          served by Allmyles (ex. 'airports').
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an array.

  .. warning::
      The methods below are only documented for the sake of completeness. Only
      use them if you really, *really* need to. The methods of the
      :php:class:`Flights\\Combination` class handle using all these
      automatically.

  .. php:method:: getFlightDetails($bookingId[, $session = null])

      Gets the details of the given booking ID from the Allmyles API. In almost
      all cases, this should not be directly called, use
      :php:meth:`Flights\\Combination::getDetails()` instead.

      :param string $bookingId:
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: bookFlight($parameters[, $session = null])

      Sends a book request to the Allmyles API. In almost all cases, this
      should not be directly called, use
      :php:meth:`Flights\\Combination::book()` instead.

      :param array $parameters:
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: addPayuPayment($payuId[, $session = null])

      Sends a PayU transaction ID to the Allmyles API to confirm that payment
      was successful. In almost all cases, this should not be directly called,
      use :php:meth:`Flights\\Combination::addPayuPayment()` instead.

      :param string $payuId:
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: createFlightTicket($bookingId[, $session = null])

      Gets a ticket for the given booking ID from the Allmyles API. In almost
      all cases, this should not be directly called, use
      :php:meth:`Flights\\Combination::createTicket()` instead.

      :param string $bookingId:
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: getHotelDetails($hotel)

      Gets the details of the given hotel from the Allmyles API. In almost
      all cases, this should not be directly called, use
      :php:meth:`Hotels\\Hotel::getDetails()` instead.

      :param object $hotel: This should be a :php:class:`Hotels\\Hotel` object

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: getHotelRoomDetails($room)

      Gets the details of the given room from the Allmyles API. In almost
      all cases, this should not be directly called, use
      :php:meth:`Hotels\\Room::getDetails()` instead.

      :param object $room: This should be a :php:class:`Hotels\\Room` object

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: getHotelRoomDetails($room)

      Gets the details of the given room from the Allmyles API. In almost
      all cases, this should not be directly called, use
      :php:meth:`Hotels\\Room::getDetails()` instead.

      :param object $room: This should be a :php:class:`Hotels\\Room` object

      :returns: A :php:class:`Curl\\Response` object.

  .. php:method:: bookHotel($parameters[, $session = null])

      Sends a book request to the Allmyles API. In almost all cases, this
      should not be directly called, use
      :php:meth:`Hotels\\Room::book()` instead.

      :param array $parameters:
      :param string $session:

      :returns: A :php:class:`Curl\\Response` object.

.. php:namespace:: Allmyles\Curl

.. php:class:: Response

  A response from the Allmyles API. Methods that are for internal use only are
  excluded from this documentation (such as ``__construct()``.)

  .. php:method:: get()

      Processes the received response, and returns the processed result.

      :returns: Varies per call, check the notes next to the return values in
          this documentation to find out what ``get()`` will return.

  .. php:method:: retry()

      Retries the request that resulted in this response. This comes in handy
      when making async calls.

      :returns: A new :php:class:`Curl\\Response` object.

.. php:namespace:: Allmyles\Flights

.. php:class:: SearchQuery

  This is the object you can pass to a
  :php:meth:`Allmyles\\Client::searchFlight()` call to simplify searching.

  .. php:method:: __construct($fromLocation, $toLocation, $departureDate[, $returnDate = null])

      Starts building a search query. Searches for a one way flight if no
      ``$returnDate`` is given.

      :param string $fromLocation: A location's three letter IATA code.
      :param string $toLocation: A location's three letter IATA code.
      :param mixed $departureDate: Either an ISO formatted timestamp, or a
        :php:class:`DateTime` object.
      :param mixed $returnDate: Either an ISO formatted timestamp, or a
        :php:class:`DateTime` object.

      :returns: A :php:class:`SearchQuery` object.

  .. php:method:: addPassengers($adt[, $chd = 0, $inf = 0])

      Adds the number of passengers to your search query. This is required for
      your search request to go through.

      :param integer $adt: The number of adults wanting to travel.
      :param integer $chd: The number of children wanting to travel.
      :param integer $inf: The number of infants wanting to travel.

  .. php:method:: addProviderFilter($providerType)

      Adds a filter to your query that restricts the search to a specific
      provider.

      :param string $providerType: The provider to filter to. Use the following
        contants:

      .. php:const:: PROVIDER_ALL

      All providers

      .. php:const:: PROVIDER_TRADITIONAL

      Traditional flights only

      .. php:const:: PROVIDER_LOWCOST

      LCC flights only

  .. php:method:: addAirlineFilter($airlines)

      Adds a filter to your query that restricts the search to specific
      airlines.

      :param mixed $providerType: Either a two letter IATA airline code as a
        string, or an array of multiple such strings.

.. php:class:: FlightResult

  .. php:attr:: combinations

    An associative array of booking ID to :php:class:`Combination` key-value
    pairs.

    Contains the combinations the passenger can choose from in this result.

  .. php:attr:: breakdown

    An associative array.

    Contains a breakdown of fares per passenger type. See :ref:`Breakdown`.

  .. php:attr:: totalFare

    A :php:class:`Common\\Price` object.

    Contains the fare total to the best of our knowledge at this point.

.. php:class:: Combination

  This is the bookable entity, and these methods are where most of the magic
  happens.

  .. php:attr:: flightResult

    A :php:class:`FlightResult` object.

    Contains the parent flight result.

  .. php:attr:: bookingId

    A string.

    Contains the booking ID associated with this combination.

  .. php:attr:: providerType

    A string.

    Contains the provider that returned this result.

  .. php:attr:: legs

    An array of :php:class:`Leg` objects.

    Contains the legs that this combination consists of.

  .. php:attr:: serviceFee

    A :php:class:`Common\\Price` object.

    Contains the service fee for this combination.

  .. php:method:: getDetails()

      Sends the flight details request for this flight.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an associative array
        with the response from the Allmyles API in it. See
        :ref:`Flight_Details`.

  .. php:method:: book($parameters)

      Sends the book request for this flight.

      :param mixed $parameters: Either a :php:class:`BookQuery` object, or an
        associative array containing the raw data to be sent off based on the
        :ref:`Flight_Booking` API docs.

      :returns: Either ``true`` when booking LCC, or a
        :php:class:`Curl\\Response` object for traditional flights.
        Calling :php:meth:`Curl\\Response::get()` on this returns an
        associative array with the response from the Allmyles API in it. See
        :ref:`Flight_Booking`.

  .. php:method:: addPayuPayment($payuId)

      Sends the PayU transaction ID to confirm that payment for the ticket
      has been completed for this flight.

      :param string $payuId: The PayU transaction ID to confirm payment with.

      :returns: ``true``

  .. php:method:: createTicket()

      Sends the ticket creation request for this flight.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an associative array
        with the response from the Allmyles API in it. See
        :ref:`Flight_Ticketing`.

.. php:class:: Leg

  .. php:attr:: combination

    A :php:class:`Combination` object.

    Contains the parent combination.

  .. php:attr:: length

    A :php:class:`DateInterval` object

    Contains the length of the leg in hours and minutes.

  .. php:attr:: segments

    An array of :php:class:`Segment` objects.

    Contains the segments of this leg.

.. php:class:: Segment

  .. php:attr:: leg

    A :php:class:`Leg` object.

    Contains the parent leg.

  .. php:attr:: arrival

    A :php:class:`Stop` object

    Contains details about the arrival stop.

  .. php:attr:: departure

    A :php:class:`Stop` object.

    Contains details about the departure stop.

  .. php:attr:: airline

    A string.

    Contains the two character IATA code of the affiliated airline.

  .. php:attr:: flightNumber

    A string.

    Contains the flight's number.

  .. php:attr:: availableSeats

    An integer.

    Contains the number of seats left at this price.

  .. php:attr:: cabin

    A string.

    Contains which cabin the passenger will get a ticket to on this segment.

.. php:class:: Stop

  .. php:attr:: segment

    A :php:class:`Segment` object.

    Contains the parent segment.

  .. php:attr:: time

    A :php:class:`DateTime` object

    Contains the time of the arrival or departure.

  .. php:attr:: airport

    A string.

    Contains the three letter IATA code of the airport where the arrival or
    departure is going to take place.

  .. php:attr:: terminal

    A string, or ``null``.

    Contains the terminal of the airport where the arrival or departure is
    going to take place, or ``null`` if the airport only has one terminal.

.. php:class:: BookQuery

  This is the object you can pass to a
  :php:meth:`Flights\\Combination::book()` call to simplify booking.

  .. php:method:: __construct([$passengers = null, $contactInfo = null, $billingInfo = null])

      Starts building a book query.

      :param array $passengers: The details of the people wanting to travel.
        See :ref:`Passenger` in the API docs.
      :param array $contactInfo: The contact details to book the flight with.
        See :ref:`Contact` in the API docs.
      :param array $billingInfo: The billing details to book the flight with.
        See :ref:`Contact` in the API docs.

      :returns: A :php:class:`BookQuery` object.

  .. php:method:: addPassengers($passengers)

      Adds passengers to your book query.

      :param array $passengers: Either an associative array containing data
        based on :ref:`Passenger` in the API docs, or an array of multiple such
        arrays.

  .. php:method:: addContactInfo($address)

      Adds contact info to your book query.

      :param array $address: The contact details to book the flight with.
        See :ref:`Contact` in the API docs.

  .. php:method:: addBillingInfo($address)

      Adds billing info to your book query.

      :param array $address: The billing details to book the flight with.
        See :ref:`Contact` in the API docs.

.. php:namespace:: Allmyles\Hotels

.. php:class:: SearchQuery

  This is the object you can pass to a
  :php:meth:`Allmyles\\Client::searchHotel()` call to simplify searching.

  .. php:method:: __construct($location, $arrivalDate, $leaveDate[, $occupants = 1])

      Starts building a search query.

      :param string $location: A location's three letter IATA code.
      :param mixed $arrivalDate: Either an ISO formatted date (ex. 2014-12-24),
        or a :php:class:`DateTime` object.
      :param mixed $leaveDate: Either an ISO formatted date (ex. 2014-12-24),
        or a :php:class:`DateTime` object.
      :param integer $occupants: The number of occupants looking for a hotel.

      :returns: A :php:class:`SearchQuery` object.

.. php:class:: BookQuery

  This is the object you can pass to a
  :php:meth:`Flights\\Combination::book()` call to simplify booking.

  .. php:method:: __construct([$occupants = null, $contactInfo = null, $billingInfo = null])

      Starts building a book query.

      :param array $occupants: The details of the people wanting to travel.
        See :ref:`Passenger` in the API docs.
      :param array $contactInfo: The contact details to book the hotel with.
        See :ref:`Contact` in the API docs.
      :param array $billingInfo: The billing details to book the hotel with.
        See :ref:`Contact` in the API docs.

      :returns: A :php:class:`BookQuery` object.

  .. php:method:: addOccupants($occupants)

      Adds occupants to your book query.

      :param array $occupants: Either an associative array containing data
        based on :ref:`Passenger` in the API docs, or an array of multiple such
        arrays.

  .. php:method:: addContactInfo($address)

      Adds contact info to your book query.

      :param array $address: The contact details to book the flight with.
        See :ref:`Contact` in the API docs.

  .. php:method:: addBillingInfo($address)

      Adds billing info to your book query.

      :param array $address: The billing details to book the flight with.
        See :ref:`Contact` in the API docs.

.. php:class:: Hotel

  This contains data about entire hotels.

  .. php:attr:: hotelId

    A string.

  .. php:attr:: hotelName

    A string.

  .. php:attr:: chainName

    A string.

  .. php:attr:: thumbnailUrl

    A string.

    Contains a link to a small image representing this hotel.

  .. php:attr:: stars

    An integer.

    Contains the amount of stars this hotel has been awarded.

  .. php:attr:: priceRange

    A :php:class:`Common\\PriceRange` object.

    Contains the available rates for this hotel (for the cheapest and the most
      expensive room).

  .. php:attr:: location

    A :php:class:`Common\\Location` object.

    Contains the coordinates of the hotel.

  .. php:attr:: amenities

    An associative array, maps strings to booleans.

    Contains whether the hotel has any of the listed amenities.

      .. hlist::
        :columns: 2

        - restaurant
        - bar
        - laundry
        - room_service
        - safe_deposit_box
        - parking
        - swimming
        - internet
        - gym
        - air_conditioning
        - business_center
        - meeting_rooms
        - spa
        - pets_allowed

  .. php:method:: getDetails()

      Sends the hotel details request for this hotel.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an associative array
        with the response from the Allmyles API (see :ref:`Hotel_Details`.),
        and also an array of bookable room objects in the 'rooms' key.

.. php:class:: Room

  This contains data about a room in a hotel.

  .. php:attr:: hotel

    A :php:class:`Hotel` object.

    Contains the parent hotel.

  .. php:attr:: hotelId

    A string.

  .. php:attr:: bookingId

    A string.

  .. php:attr:: price

    A :php:class:`Common\\Price` object.

    Contains the rate for this room. Make sure to take the values of the two
      attributes below into consideration when working with this value.

  .. php:attr:: priceVaries

    A boolean.

    If this is true, then the hotel has a different rate for at least one of
      the nights. The given price is the rate of the most expensive day.

  .. php:attr:: priceScope

    A string.

    Either 'day', or 'trip'. The given price covers this scope.

  .. php:attr:: stars

    An integer.

    Contains the amount of stars this hotel has been awarded.

  .. php:attr:: traits

    An associative array.

    Contains the traits of the given room, including the category, bed/shower
    availability, whether smoking is allowed, and whether it is a suite.

  .. php:attr:: bed

    A string.

    Specifies the type of the bed in the room. Can be one of the values below.

      .. hlist::
        :columns: 2

        - single
        - double
        - twin
        - king size
        - queen size
        - pullout
        - water bed

  .. php:attr:: description

    A string.

    Contains a short text about the room.

  .. php:attr:: quantity

    An integer.

    Contains the amount left to be booked of this room.

  .. php:method:: getDetails()

      Sends the hotel room details request for this room.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an associative array
        with the response from the Allmyles API
        (see :ref:`Hotel_Room_Details`.)

  .. php:method:: book($parameters)

      Sends the book request for this hotel.

      :param mixed $parameters: Either a :php:class:`BookQuery` object, or an
        associative array containing the raw data to be sent off based on the
        :ref:`Hotel_Booking` API docs.

      :returns: A :php:class:`Curl\\Response` object. Calling
        :php:meth:`Curl\\Response::get()` on this returns an associative array
        with the response from the Allmyles API. See :ref:`Hotel_Booking`.

.. php:namespace:: Allmyles\Common

.. php:class:: Price

  .. php:attr:: amount

    A floating point number.

    Contains the amount of money in the given currency that the price entails.

  .. php:attr:: currency

    A string.

    Contains the currency that the amount is in.

.. php:class:: PriceRange

  .. php:attr:: minimum

    A floating point number.

    Contains the minimum amount of money in the given currency that the price
      range entails.

  .. php:attr:: maximum

    A floating point number.

    Contains the maximum amount of money in the given currency that the price
      range entails.

  .. php:attr:: currency

    A string.

    Contains the currency that the amounts are in.

.. php:class:: Location

  .. php:attr:: latitude

    A floating point number.

    Contains the latitude of the location.

  .. php:attr:: longitude

    A string.

    Contains the longitude of the location.
