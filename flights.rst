=========
 Flights 
=========

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
    :jsonparam String[] airlines: *(optional)* list of airlines to filter
                                  results to, given as their IATA code

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
        - **flightResultSet** (*FlightResult[]*) -- root container (see :ref:`FlightResult`)

.. _FlightResult:

FlightResult
------------

    :JSON Parameters:
        - **breakdown** (*Breakdown[]*) -- summary of passenger data per type
          (see :ref:`Breakdown`)
        - **currency** (*String*) -- currency of all prices in response
        - **total_fare** (*Float*) -- total fare, including service fee
        - **combinations** (*Combination[]*) -- list of combination objects
          (see :ref:`Combination`)

.. _Breakdown:

Breakdown
---------

    :JSON Parameters:
        - **fare** (*Float[]*) -- total price of the tickets for passengers of
          ``type``
        - **type** (*String*) -- type of passengers the breakdown is for, see
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of passengers of ``type``
        - **ticketDesignators** (*TicketDesignator[]*) -- ticket designators applicable for passengers of ``type`` (see :ref:`TicketDesignator`)

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

    Combinations are the sets of different flights that can be booked. Every
    combination in a flight result is guaranteed to have the same total price,
    but the departure times, arrival times, and transfer locations can differ.

    .. note::
        As of May 2014, ``providerType`` can either be ``AmadeusProvider``, for
        traditional flights, or ``TravelFusionProvider``, for LCC flights.

    :JSON Parameters:
        - **providerType** (*String*) -- The provider the result is from
        - **bookingId** (*String*) -- ticket designator's description (this is
          later used to identify the combination when booking, for example.)
        - **firstLeg** (*Leg*) -- ticket designator's code
        - **serviceFeeAmount** (*Float*) -- ticket designator's description

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

        {}

