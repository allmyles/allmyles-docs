=========
 Flights
=========

---------
 Summary
---------

The flight booking/ticket creation workflow consists of four mandatory steps
for traditional flights. A fifth step (providing payment details) is required
when booking LCC flights.

 1. :ref:`Flight_Search`
 2. :ref:`Flight_Details`
 3. Booking
 4. Payment (mandatory only for LCC)
 5. Ticketing

.. _Flight_Search:

--------
 Search
--------

Request
=======

.. http:post:: /flights/

    Searches for flights that match provided criteria.

    :jsonparam String fromLocation: departure location, given as IATA code
    :jsonparam String toLocation: destination, given as IATA code
    :jsonparam String departureDate: date of departure, in ISO format
                                     *(including a time code, even though
                                     whole day will be searched by default)*
    :jsonparam String returnDate: date of return, in ISO format *(including
                                  a time code, even though whole day will be
                                  searched by default)*
    :jsonparam Person persons: a list of passengers, grouped by type code
                              containing Persons (see :ref:`Person`)
    :jsonparam String fromAirport: *(optional)* departure airport, given as
                                   IATA code, must be in the city specified in
                                   ``fromLocation``
    :jsonparam String toAirport: *(optional)* destination airport, given as
                                 IATA code, must be in the city specified in
                                 ``toLocation``
    :jsonparam String providerType: *(optional)* type of results to retrieve
    :jsonparam String[] preferredAirlines: *(optional)* list of airlines to
                                           filter results to, given as their
                                           two character IATA code

.. _Person:

Person
------

    :JSON Parameters:
        - **passengerType** (*String*) -- one of the available passenger types
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of travelers of ``passengerType``

Response
========

    :JSON Parameters:
        - **flightResultSet** (:ref:`FlightResult`\[\]) -- root container

.. _FlightResult:

FlightResult
------------

    .. warning::
        The ``total_fare`` field here does not include the credit card
        surcharge just yet, as fetching the exact surcharge for a specific
        flight can require an extra 5-10 second call to the external provider.

        This surcharge is retrieved in the _`FlightDetails` call.

    :JSON Parameters:
        - **breakdown** (:ref:`Breakdown`\[\]) -- summary of passenger data per
          type
        - **currency** (*String*) -- currency of all prices in response
        - **total_fare** (*Float*) -- total fare, including service fee
        - **combinations** (:ref:`Combination`\[\]) -- list of combination
          objects

.. _Breakdown:

Breakdown
---------

    :JSON Parameters:
        - **fare** (*Float[]*) -- total price of the tickets for passengers of
          ``type``
        - **type** (*String*) -- type of passengers the breakdown is for, see
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of passengers of ``type``
        - **ticketDesignators** (*:ref:`TicketDesignator`\[\]*) -- ticket
          designators applicable for passengers of ``type``

.. _TicketDesignator:

TicketDesignator
----------------

    Ticket designators are the mini-rules for the flight, with entries such as
    ``{"code": "70|PEN", "extension": "TICKETS ARE NON-REFUNDABLE|"}``.

    :JSON Parameters:
        - **code** (*String*) -- ticket designator's code
        - **extension** (*String*) -- ticket designator's description

.. _Combination:

Combination
-----------

    Combinations are the sets of different flight itineraries that can be
    booked. Every combination in a flight result is guaranteed to have the
    same total price, but the departure times, arrival times, and transfer
    locations can differ.

    .. note::
        As of May 2014, ``providerType`` can either be ``AmadeusProvider``, for
        traditional flights, or ``TravelFusionProvider``, for LCC flights.

    :JSON Parameters:
        - **providerType** (*String*) -- the provider the result is from
        - **bookingId** (*String*) -- the unique identifier of this
          combination (this is later used to identify the combination when
          booking, for example.)
        - **firstLeg** (:ref:`Leg`) -- The outbound leg of the itinerary
        - **returnLeg** (:ref:`Leg`) -- The inbound leg of the itinerary
        - **serviceFeeAmount** (*Float*) -- ticket designator's description

.. _Leg:

Leg
---

    Legs are made up of one or more segment, and span from one location the
    customer searched for to the other.

    :JSON Parameters:
        - **elapsedTime** (*String*) -- The total time between the leg's first
          departure, and last arrival (including time spent waiting when
          transferring). It is given in the format ``HHMM``.
        - **flightSegments** (:ref:`Segment`\[\]) -- The list of segments this
          leg is made up of.

.. _Segment:

Segment
-------

    Segments are the smallest unit of an itinerary. They are the direct
    flights the passenger will take from one airport to the other.

    :JSON Parameters:
        - **departure** (:ref:`Stop`) -- data about the flight's departure
        - **arrival** (:ref:`Stop`) -- data about the flight's arrival
        - **operatingAirline** (*String*) -- The airline operating this
          specific segment, given as a two character IATA code.
        - **availableBookingClasses** (*BookingClass[]*) -- a list of the
          classes that can be booked for this specific segment

          - **cabinCode** (*String*) --
          - **code** (*String*) --
          - **quantity** (*Integer*) --

.. _Stop:

Stop
----

    A stop is either the departure, or the arrival part of a segment.

    :JSON Parameters:
        - **dateTime** (*String*) -- time of the stop (in ISO format)
        - **airport** (*Airport*) -- location of the stop

          - **terminal** -- the relevant terminal of the airport specified
            below (this will be ``null`` is the airport has only one terminal)
          - **code** -- the three letter IATA code of the airport the stop is
            at

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "fromLocation": "BUD",
          "toLocation": "LON",
          "departureDate": "2014-05-15T00:00:00",
          "returnDate": "2014-05-20T00:00:00",
          "persons":[
            {
              "passengerType":"ADT",
              "quantity": 2
            },
            {
              "passengerType":"CHD",
              "quantity": 1
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightResultSet": [
            {
              "breakdown": [
                {
                  "passengerFare": {
                    "fare": 52.8627,
                    "ticketDesignators": [],
                    "type": "ADT",
                    "quantity": 1
                  }
                }
              ],
              "currency": "EUR",
              "total_fare": 57.8627,
              "combinations": [
                {
                  "providerType": "TravelFusionProvider",
                  "bookingId": "15_0_0",
                  "firstLeg": {
                    "elapsedTime": "0230",
                    "flightSegments": [
                      {
                        "arrival": {
                          "airport": {
                            "terminal": null,
                            "code": "STN"
                          },
                          "dateTime": "2014-06-05T23:00:00"
                        },
                        "operatingAirline": "FR",
                        "departure": {
                          "airport": {
                            "terminal": null,
                            "code": "BUD"
                          },
                          "dateTime": "2014-06-05T21:30:00"
                        },
                        "availableBookingClasses": [
                          {
                            "cabinCode": "Y",
                            "code": "Y",
                            "quantity": 0
                          }
                        ]
                      }
                    ]
                  },
                  "serviceFeeAmount": 5.0
                }
              ]
            }
          ]
        }

.. _Flight_Details:

---------
 Details
---------

Request
=======

.. http:get:: /flights/(bookingId)

    :getparam bookingId: the booking ID of the :ref:`Combination` to get the
                         details of

Response
========

    .. warning::
        Due to a bug, the current development nightly has a second
        ``flightDetails`` container inside this one. This will be fixed with
        the next deployment. We apologize for the inconvenience. We really do.

    :JSON Parameters:
        - **flightDetails** (:ref:`FlightDetailsContainer`) -- root container

.. _FlightDetailsContainer:

FlightDetails
-------------

    .. warning::
        While the ``price`` field contains the ticket's final price, baggages
        are not included in that, as the user may be able to choose from
        different baggage tiers. It is the travel site's responsibility to add
        the cost of the passenger's baggages themselves as an extra cost.

    .. note::
        Providers return prices in the travel site's preferred currency
        automatically. In the rare case that they might fail to do so, the
        Allmyles API will convert the prices to the flight fare's currency
        automatically, based on the provider's currency conversion data.

    :JSON Parameters:
        - **rulesLink** (*String*) -- link to the airline's rules page (hosted
          on the airline's website)
        - **baggageTiers** (:ref:`BaggageTier`) -- contains the different
          options the passenger has for bringing baggages along.
        - **fields** (:ref:`FormFields`) -- contains field validation data.
        - **price** (:ref:`Price`) -- contains the final price of the ticket
          (including the credit card surcharge, but not the baggages)
        - **result** (:ref:`FlightResult`) -- contains an exact copy of the result
          from the :ref:`Flight_Search` call's response
        - **options** (:ref:`FlightOption`) -- contains whether certain options are
          enabled for this flight
        - **surcharge** (:ref:`Price`) -- contains the credit card surcharge
          for this flight

.. _BaggageTier:

BaggageTier
-----------

Not implemented currently. Estimated to be added during the week of May 19.

.. _FormFields:

FormFields
----------

    **{fieldName}** below refers to the following names:

    .. hlist::
        :columns: 3

        - addressLine1
        - addressLine2
        - addressLine3
        - baggage
        - billingAddressLine1
        - billingAddressLine2
        - billingAddressLine3
        - billingCityName
        - billingCountryCode
        - billingZipCode
        - birthDate
        - cityName
        - countryCode
        - documentExpiryDate
        - documentId
        - documentIssuingCountry
        - documentType
        - email
        - firstName
        - gender
        - lastName
        - namePrefix
        - passengerTypeCode
        - phoneAreaCode
        - phoneCountryCode
        - phoneNumber
        - zipCode

    :JSON Parameters:
        - **{fieldName}** (*FormField*) -- Contains validation data for
          a field type

          - **required** (*Boolean*) -- Specifies whether the
          - **per_person** (*Boolean*) -- Contains field validation data.

    The different combinations of the values of `required` and `per_person`
    carry the following meaning:

    ======== ========== =======================================================
    required per_person meaning
    ======== ========== =======================================================
    True     True       Passing data for this field is mandatory for each
                        individual passenger.
    True     False      Passing data for this field is mandatory, but only for
                        the first passenger, or it requires a universal value
                        for the booking,such as `billingCityName`.
    False    True       Passing data for this field is not mandatory, but it
                        refers to something that can be different for each
                        passenger, such as `gender`.
    False    False      Passing data for this field is not mandatory, and it
                        refers to something that is universal for the booking,
                        such as `billingAddressLine3`.
    ======== ========== =======================================================

.. _Price:

Price
-----

    :JSON Parameters:
        - **amount** (*Float*) -- the amount of money in the currency below
        - **currency** (*String*) -- the currency of the amount specified

.. _FlightOptions:

FlightOptions
-------------

    **{optionName}** below refers to the following names:

    .. hlist::
        :columns: 3

        - seatSelectionAvailable
        - travelfusionPrepayAvailable

    :JSON Parameters:
        - **{optionName}** (*Boolean*) -- whether the option is enabled or not


Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightDetails": {
            "rulesLink": null,
            "baggageTiers": [],
            "fields": {
              "countryCode": {
                "required": true,
                "per_person": false
              },
              "documentType": {
                "required": true,
                "per_person": true
              }
            },
            "price": {
              "currency": "EUR",
              "amount": 4464.46
            },
            "result": {},
            "options": {
              "seatSelectionAvailable": false,
              "travelfusionPrepayAvailable": false
            },
            "surcharge": {
              "currency": "EUR",
              "amount": 5.0
            }
          }
        }

.. _FlightBooking:

---------
 Booking
---------

Request
=======

Response
========

Examples
========

Request
-------

Response
--------

.. _FlightPayment:

---------
 Payment
---------

Request
=======

Response
========

Examples
========

Request
-------

Response
--------

.. _FlightTicketing:

-----------
 Ticketing
-----------

Request
=======

Response
========

Examples
========

Request
-------

Response
--------

